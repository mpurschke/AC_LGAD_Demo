library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

-- PL part of the two-Zybo DAQ demo (step 1: one board, clock from its own sysclk).
-- Sits in the block design as a module reference next to the PS7.
--
-- Two clock domains:
--   clk_ts : shared clock from the MMCM (125 MHz). Timestamp, triggers, events.
--   s_axi_aclk : the PS clock FCLK0 (100 MHz). Registers. The event stream
--                crosses into it through an async AXI-Stream FIFO in the block design.
-- The AXI side never depends on the MMCM, so a missing clock (later: no HDMI
-- cable on a consumer) cannot hang the processor on a register access.
--
-- Switches: SW3 = clock master (on), SW1..0 = board id (also the IP address
-- 192.168.80.100 + id). BTN0 = one trigger, BTN1 = trigger train while held.
-- LEDs: LD0 = trigger (50 ms flash), LD1 = run enabled, LD2 = drops since clear,
-- LD3 = heartbeat of the shared clock. RGB LD6: red = MMCM not locked,
-- blue = clock master, green = consumer.
--
-- Registers (byte offsets):
--   0x00 VERSION      RO  0x5A44nnnn
--   0x04 CONTROL      RW  bit0 enable; bit1 clear (write 1: zero timestamp, numbers, counters; reads 0)
--   0x08 STATUS       RO  bit0 master (SW3), bit1 MMCM locked, bits 5..4 board id, bit8 enable, bit9 drops since clear
--   0x0C INPUTS       RO  bits 3..0 switches, bits 11..8 buttons (raw, synchronized)
--   0x10 TRAIN_PERIOD RW  clocks of the shared clock between train triggers (default 1_250_000 = 10 ms)
--   0x14 (unused, reads 0)
--   0x18 TRIG_COUNT   RO  triggers while enabled
--   0x1C EVT_COUNT    RO  events sent
--   0x20 DROP_COUNT   RO  triggers dropped
--   0x24 SOFT_TRIG    WO  write anything: one trigger (also on a consumer, for tests)
entity zdaq_pl is
  generic (
    DEBOUNCE_TICK : positive := 125_000     -- 1 ms at 125 MHz; small in simulation
  );
  port (
    sysclk    : in  std_logic;                        -- 125 MHz, K17
    btn       : in  std_logic_vector(3 downto 0);
    sw        : in  std_logic_vector(3 downto 0);
    led       : out std_logic_vector(3 downto 0);
    led6_r    : out std_logic;
    led6_g    : out std_logic;
    led6_b    : out std_logic;
    eth_rst_b : out std_logic;                        -- Ethernet PHY reset, must be high

    -- event stream, on the shared clock
    m_axis_aclk    : out std_logic;
    m_axis_aresetn : out std_logic;
    m_axis_tdata   : out std_logic_vector(31 downto 0);
    m_axis_tvalid  : out std_logic;
    m_axis_tready  : in  std_logic;
    m_axis_tlast   : out std_logic;

    -- registers, on FCLK0
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(5 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(5 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic
  );
end entity;

architecture rtl of zdaq_pl is
  constant VERSION : std_logic_vector(31 downto 0) := x"5A440002";

  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of m_axis_aclk : signal is "xilinx.com:signal:clock:1.0 m_axis_aclk CLK";
  attribute X_INTERFACE_PARAMETER of m_axis_aclk : signal is
    "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET m_axis_aresetn, FREQ_HZ 125000000";
  attribute X_INTERFACE_INFO of m_axis_aresetn : signal is "xilinx.com:signal:reset:1.0 m_axis_aresetn RST";
  attribute X_INTERFACE_PARAMETER of m_axis_aresetn : signal is "POLARITY ACTIVE_LOW";
  attribute X_INTERFACE_INFO of s_axi_aclk : signal is "xilinx.com:signal:clock:1.0 s_axi_aclk CLK";
  attribute X_INTERFACE_PARAMETER of s_axi_aclk : signal is
    "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn";

  -- clock
  signal sysclk_b, clkfb, clkfb_b, clk0, clk_ts, locked : std_logic;
  signal rst_ts, locked_n : std_logic;

  -- shared-clock domain
  signal btn_db, sw_db : std_logic_vector(3 downto 0);
  signal trig : std_logic;
  signal enable_ts, clear_ts, soft_ts : std_logic;
  signal period_ts : std_logic_vector(31 downto 0);
  signal trig_cnt, evt_cnt, drop_cnt : unsigned(31 downto 0);
  signal dropped : std_logic;
  signal flash : unsigned(22 downto 0) := (others => '0');    -- 50 ms trigger flash
  signal beat  : unsigned(26 downto 0) := (others => '0');

  -- AXI domain
  signal awready, wready, bvalid, arready, rvalid : std_logic := '0';
  signal rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal r_enable : std_logic := '0';
  signal r_period : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(1_250_000, 32));
  signal clear_pls, soft_pls : std_logic := '0';
  signal sw_a, btn_a : std_logic_vector(3 downto 0);
  signal st_ts, st_a : std_logic_vector(2 downto 0);   -- locked-independent status from the ts domain
  signal locked_a : std_logic;
  signal trig_a, evt_a, drop_a : std_logic_vector(31 downto 0);
begin
  eth_rst_b <= '1';

  ---------------------------------------------------------------- clock
  -- CLKIN2 / CLKINSEL are kept for the HDMI clock of a consumer (next step);
  -- for now the MMCM always runs from this board's sysclk.
  ibufg_i : IBUFG port map (I => sysclk, O => sysclk_b);

  mmcm_i : MMCME2_ADV
    generic map (
      BANDWIDTH       => "OPTIMIZED",
      CLKIN1_PERIOD   => 8.0,
      CLKIN2_PERIOD   => 8.0,
      DIVCLK_DIVIDE   => 1,
      CLKFBOUT_MULT_F => 8.0,        -- VCO 1000 MHz
      CLKOUT0_DIVIDE_F => 8.0        -- 125 MHz
    )
    port map (
      CLKIN1 => sysclk_b, CLKIN2 => sysclk_b, CLKINSEL => '1',
      CLKFBIN => clkfb_b, CLKFBOUT => clkfb, CLKOUT0 => clk0,
      LOCKED => locked, RST => '0', PWRDWN => '0',
      DADDR => (others => '0'), DCLK => '0', DEN => '0', DI => (others => '0'), DWE => '0',
      PSCLK => '0', PSEN => '0', PSINCDEC => '0'
    );
  bufg_fb : BUFG port map (I => clkfb, O => clkfb_b);
  bufg_ts : BUFG port map (I => clk0,  O => clk_ts);

  rst_sync : xpm_cdc_async_rst
    generic map (DEST_SYNC_FF => 4, RST_ACTIVE_HIGH => 1)
    port map (src_arst => locked_n, dest_clk => clk_ts, dest_arst => rst_ts);
  locked_n <= not locked;

  m_axis_aclk    <= clk_ts;
  m_axis_aresetn <= not rst_ts;

  ---------------------------------------------------------------- shared-clock domain
  db_i : entity work.debounce
    generic map (N => 8, TICK => DEBOUNCE_TICK, STABLE => 8)
    port map (clk => clk_ts,
              din(3 downto 0) => btn, din(7 downto 4) => sw,
              dout(3 downto 0) => btn_db, dout(7 downto 4) => sw_db);

  tg_i : entity work.trig_gen
    port map (clk => clk_ts, rst => rst_ts, allow => sw_db(3),
              btn_single => btn_db(0), btn_train => btn_db(1), soft => soft_ts,
              period => unsigned(period_ts), trig => trig);

  eg_i : entity work.evt_gen
    port map (clk => clk_ts, rst => rst_ts, clear => clear_ts, enable => enable_ts,
              trig => trig,
              m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
              m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast,
              trig_count => trig_cnt, evt_count => evt_cnt, drop_count => drop_cnt,
              dropped => dropped);

  process (clk_ts)
  begin
    if rising_edge(clk_ts) then
      beat <= beat + 1;
      if trig = '1' then
        flash <= to_unsigned(6_250_000, flash'length);
      elsif flash /= 0 then
        flash <= flash - 1;
      end if;
    end if;
  end process;

  led(0) <= '1' when flash /= 0 else '0';
  led(1) <= enable_ts;
  led(2) <= dropped;
  led(3) <= beat(26);
  -- RGB at 1/8 duty, full brightness is blinding
  led6_r <= (not locked) and beat(2) and beat(1) and beat(0);
  led6_b <= locked and sw_db(3) and beat(2) and beat(1) and beat(0);
  led6_g <= locked and not sw_db(3) and beat(2) and beat(1) and beat(0);

  ---------------------------------------------------------------- crossings
  -- AXI -> shared clock: quasi-static settings, and two pulses
  cdc_ctl : xpm_cdc_array_single
    generic map (WIDTH => 33, SRC_INPUT_REG => 1)
    port map (src_clk => s_axi_aclk, src_in(0) => r_enable, src_in(32 downto 1) => r_period,
              dest_clk => clk_ts, dest_out(0) => enable_ts, dest_out(32 downto 1) => period_ts);

  cdc_clear : xpm_cdc_pulse
    generic map (RST_USED => 0)
    port map (src_clk => s_axi_aclk, src_pulse => clear_pls, src_rst => '0',
              dest_clk => clk_ts, dest_pulse => clear_ts, dest_rst => '0');

  cdc_soft : xpm_cdc_pulse
    generic map (RST_USED => 0)
    port map (src_clk => s_axi_aclk, src_pulse => soft_pls, src_rst => '0',
              dest_clk => clk_ts, dest_pulse => soft_ts, dest_rst => '0');

  -- shared clock -> AXI: counters (gray coded), status bits, raw inputs
  cdc_trig : xpm_cdc_gray
    generic map (WIDTH => 32)
    port map (src_clk => clk_ts, src_in_bin => std_logic_vector(trig_cnt),
              dest_clk => s_axi_aclk, dest_out_bin => trig_a);
  cdc_evt : xpm_cdc_gray
    generic map (WIDTH => 32)
    port map (src_clk => clk_ts, src_in_bin => std_logic_vector(evt_cnt),
              dest_clk => s_axi_aclk, dest_out_bin => evt_a);
  cdc_drop : xpm_cdc_gray
    generic map (WIDTH => 32)
    port map (src_clk => clk_ts, src_in_bin => std_logic_vector(drop_cnt),
              dest_clk => s_axi_aclk, dest_out_bin => drop_a);

  st_ts <= dropped & enable_ts & '0';
  cdc_st : xpm_cdc_array_single
    generic map (WIDTH => 3, SRC_INPUT_REG => 0)
    port map (src_clk => clk_ts, src_in => st_ts, dest_clk => s_axi_aclk, dest_out => st_a);

  -- LOCKED, switches and buttons come straight from asynchronous sources
  cdc_raw : xpm_cdc_array_single
    generic map (WIDTH => 9, SRC_INPUT_REG => 0)
    port map (src_clk => '0', src_in(0) => locked, src_in(4 downto 1) => sw,
              src_in(8 downto 5) => btn, dest_clk => s_axi_aclk,
              dest_out(0) => locked_a, dest_out(4 downto 1) => sw_a, dest_out(8 downto 5) => btn_a);

  ---------------------------------------------------------------- AXI-Lite registers
  -- One write and one read at a time; the address is taken when both AW and W are valid.
  process (s_axi_aclk)
    variable a : natural;
  begin
    if rising_edge(s_axi_aclk) then
      clear_pls <= '0';
      soft_pls  <= '0';
      if s_axi_aresetn = '0' then
        awready  <= '0';
        wready   <= '0';
        bvalid   <= '0';
        r_enable <= '0';
        r_period <= std_logic_vector(to_unsigned(1_250_000, 32));
      else
        if awready = '0' and s_axi_awvalid = '1' and s_axi_wvalid = '1' and bvalid = '0' then
          awready <= '1';
          wready  <= '1';
        elsif awready = '1' then                     -- handshake happens in this cycle
          awready <= '0';
          wready  <= '0';
          bvalid  <= '1';
          a := to_integer(unsigned(s_axi_awaddr(5 downto 2)));
          case a is
            when 1 =>
              r_enable  <= s_axi_wdata(0);
              clear_pls <= s_axi_wdata(1);
            when 4 => r_period <= s_axi_wdata;
            when 9 => soft_pls <= '1';
            when others => null;
          end case;
        end if;
        if bvalid = '1' and s_axi_bready = '1' then
          bvalid <= '0';
        end if;
      end if;
    end if;
  end process;

  process (s_axi_aclk)
    variable a : natural;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn = '0' then
        arready <= '0';
        rvalid  <= '0';
      else
        if arready = '0' and s_axi_arvalid = '1' and rvalid = '0' then
          arready <= '1';
        elsif arready = '1' then
          arready <= '0';
          rvalid  <= '1';
          a := to_integer(unsigned(s_axi_araddr(5 downto 2)));
          case a is
            when 0 => rdata <= VERSION;
            when 1 => rdata <= (0 => r_enable, others => '0');
            when 2 => rdata <= (0 => sw_a(3), 1 => locked_a, 5 => sw_a(1), 4 => sw_a(0),
                                8 => st_a(1), 9 => st_a(2), others => '0');
            when 3 => rdata <= x"00000" & btn_a & x"0" & sw_a;
            when 4 => rdata <= r_period;
            when 6 => rdata <= trig_a;
            when 7 => rdata <= evt_a;
            when 8 => rdata <= drop_a;
            when others => rdata <= (others => '0');
          end case;
        end if;
        if rvalid = '1' and s_axi_rready = '1' then
          rvalid <= '0';
        end if;
      end if;
    end if;
  end process;

  s_axi_awready <= awready;
  s_axi_wready  <= wready;
  s_axi_bresp   <= "00";
  s_axi_bvalid  <= bvalid;
  s_axi_arready <= arready;
  s_axi_rdata   <= rdata;
  s_axi_rresp   <= "00";
  s_axi_rvalid  <= rvalid;
end architecture;
