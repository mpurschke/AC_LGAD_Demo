library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Self-checking testbench for zdaq_pl: registers over AXI-Lite, soft trigger,
-- BTN0 with contact bounce, BTN1 train, back-pressure with drops, and a
-- consumer board ignoring the buttons. Ends with "TB PASSED" or a failure.
entity tb_zdaq is
end entity;

architecture sim of tb_zdaq is
  constant TSYS : time := 8 ns;     -- 125 MHz sysclk
  constant TAXI : time := 10 ns;    -- 100 MHz FCLK0
  constant PERIOD : natural := 200; -- train spacing in shared-clock cycles

  signal sysclk, aclk : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal btn, sw : std_logic_vector(3 downto 0) := (others => '0');
  signal led : std_logic_vector(3 downto 0);
  signal r, g, b, eth : std_logic;

  signal ts_clk, ts_rstn : std_logic;
  signal tdata : std_logic_vector(31 downto 0);
  signal tvalid, tlast : std_logic;
  signal tready : std_logic := '1';

  signal awaddr, araddr : std_logic_vector(5 downto 0) := (others => '0');
  signal awvalid, wvalid, bready, arvalid, rready : std_logic := '0';
  signal awready, wready, bvalid, arready, rvalid : std_logic;
  signal wdata, rdata : std_logic_vector(31 downto 0) := (others => '0');
  signal bresp, rresp : std_logic_vector(1 downto 0);

  -- words seen on the stream; lastw(i) = '1' if word i had TLAST
  type words_t is array (0 to 1023) of std_logic_vector(31 downto 0);
  signal words : words_t;
  signal lastw : std_logic_vector(0 to 1023);
  signal nw : natural := 0;

  signal done : boolean := false;
begin
  sysclk <= not sysclk after TSYS/2 when not done;
  aclk   <= not aclk   after TAXI/2 when not done;

  dut : entity work.zdaq_pl
    generic map (DEBOUNCE_TICK => 4)
    port map (
      sysclk => sysclk, btn => btn, sw => sw, led => led,
      led6_r => r, led6_g => g, led6_b => b, eth_rst_b => eth,
      m_axis_aclk => ts_clk, m_axis_aresetn => ts_rstn,
      m_axis_tdata => tdata, m_axis_tvalid => tvalid, m_axis_tready => tready, m_axis_tlast => tlast,
      s_axi_aclk => aclk, s_axi_aresetn => aresetn,
      s_axi_awaddr => awaddr, s_axi_awprot => "000", s_axi_awvalid => awvalid, s_axi_awready => awready,
      s_axi_wdata => wdata, s_axi_wstrb => "1111", s_axi_wvalid => wvalid, s_axi_wready => wready,
      s_axi_bresp => bresp, s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr, s_axi_arprot => "000", s_axi_arvalid => arvalid, s_axi_arready => arready,
      s_axi_rdata => rdata, s_axi_rresp => rresp, s_axi_rvalid => rvalid, s_axi_rready => rready);

  -- stream sink
  process (ts_clk)
  begin
    if rising_edge(ts_clk) then
      if tvalid = '1' and tready = '1' then
        words(nw) <= tdata;
        lastw(nw) <= tlast;
        nw <= nw + 1;
      end if;
    end if;
  end process;

  process
    variable rd : natural := 0;          -- next word of the stream to check
    variable v : std_logic_vector(31 downto 0);
    variable ts_prev : unsigned(63 downto 0);

    procedure axi_write(addr : natural; data : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(aclk);
      awaddr <= std_logic_vector(to_unsigned(addr, 6));  awvalid <= '1';
      wdata  <= data;  wvalid <= '1';  bready <= '1';
      loop
        wait until rising_edge(aclk);
        exit when awready = '1';
      end loop;
      awvalid <= '0';  wvalid <= '0';
      loop
        wait until rising_edge(aclk);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
    end procedure;

    procedure axi_read(addr : natural; data : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(aclk);
      araddr <= std_logic_vector(to_unsigned(addr, 6));  arvalid <= '1';  rready <= '1';
      loop
        wait until rising_edge(aclk);
        exit when arready = '1';
      end loop;
      arvalid <= '0';
      loop
        wait until rising_edge(aclk);
        exit when rvalid = '1';
      end loop;
      data := rdata;
      rready <= '0';
    end procedure;

    procedure check_reg(addr : natural; expect : natural; what : string) is
      variable d : std_logic_vector(31 downto 0);
    begin
      axi_read(addr, d);
      assert unsigned(d) = expect
        report what & ": got " & integer'image(to_integer(unsigned(d))) &
               ", expected " & integer'image(expect) severity failure;
    end procedure;

    -- wait for one complete event (7 words) and check it; returns its timestamp
    procedure check_event(num : natural; ts : out unsigned(63 downto 0)) is
      type tags_t is array (4 to 6) of std_logic_vector(31 downto 0);
      constant TAGS : tags_t := (x"FEEDC0DE", x"DECAFBAD", x"F0F0F0F0");
    begin
      for t in 1 to 100000 loop
        exit when nw >= rd + 7;
        wait until rising_edge(ts_clk);
      end loop;
      assert nw >= rd + 7 report "event " & integer'image(num) & " did not arrive" severity failure;
      assert unsigned(words(rd)) = 28 report "event " & integer'image(num) & ": length word wrong" severity failure;
      ts := unsigned(words(rd+2)) & unsigned(words(rd+1));
      assert unsigned(words(rd+3)) = num
        report "packet counter: got " & integer'image(to_integer(unsigned(words(rd+3)))) &
               ", expected " & integer'image(num) severity failure;
      for i in 4 to 6 loop
        assert words(rd+i) = TAGS(i) report "event " & integer'image(num) & ": tag word " & integer'image(i) & " wrong" severity failure;
      end loop;
      for i in 0 to 6 loop
        assert (lastw(rd+i) = '1') = (i = 6) report "event " & integer'image(num) & ": TLAST misplaced" severity failure;
      end loop;
      rd := rd + 7;
    end procedure;

    procedure press(i : natural; hold : time) is
    begin
      for k in 1 to 3 loop                -- contact bounce
        btn(i) <= '1';  wait for 30 ns;
        btn(i) <= '0';  wait for 20 ns;
      end loop;
      btn(i) <= '1';  wait for hold;
      btn(i) <= '0';  wait for 1 us;     -- debounce release
    end procedure;

    variable ts : unsigned(63 downto 0);
  begin
    sw <= "1010";                         -- clock master, board id 2
    wait for 100 ns;
    aresetn <= '1';

    -- MMCM lock
    for t in 1 to 200 loop
      axi_read(16#08#, v);
      exit when v(1) = '1';
      wait for 100 ns;
    end loop;
    assert v(1) = '1' report "MMCM did not lock" severity failure;

    check_reg(16#00#, 16#5A440002#, "VERSION");
    check_reg(16#10#, 1_250_000, "TRAIN_PERIOD default");
    axi_read(16#08#, v);
    assert v(0) = '1' and v(5 downto 4) = "10" report "STATUS: master / board id wrong" severity failure;

    axi_write(16#10#, std_logic_vector(to_unsigned(PERIOD, 32)));
    axi_write(16#04#, x"00000003");       -- enable + clear
    wait for 1 us;

    -- 1. soft trigger: event 0
    axi_write(16#24#, x"00000001");
    check_event(0, ts);
    report "soft trigger ok";

    -- 2. BTN0 with bounce: exactly one event
    press(0, 1 us);
    check_event(1, ts);
    wait for 2 us;
    assert nw = rd report "BTN0 gave more than one event" severity failure;
    report "BTN0 ok";

    -- 3. BTN1 held for 3.5 periods: 4 events, PERIOD clocks apart
    press(1, (7 * PERIOD * TSYS) / 2);
    check_event(2, ts_prev);
    for k in 3 to 5 loop
      check_event(k, ts);
      assert ts - ts_prev = PERIOD
        report "train spacing " & integer'image(to_integer(ts - ts_prev)) severity failure;
      ts_prev := ts;
    end loop;
    wait for 3 us;
    assert nw = rd report "BTN1 gave too many events" severity failure;
    report "BTN1 train ok";

    -- 4. back-pressure: trigger 6 gets stuck, 7 and 8 are dropped,
    --    the next event is number 9 (the gap shows the drops)
    tready <= '0';
    for k in 1 to 3 loop
      axi_write(16#24#, x"00000001");
      wait for 200 ns;
    end loop;
    tready <= '1';
    check_event(6, ts);
    axi_write(16#24#, x"00000001");
    check_event(9, ts);
    wait for 500 ns;
    check_reg(16#18#, 10, "TRIG_COUNT");
    check_reg(16#1C#, 8,  "EVT_COUNT");
    check_reg(16#20#, 2,  "DROP_COUNT");
    axi_read(16#08#, v);
    assert v(9) = '1' and v(8) = '1' report "STATUS: drop / enable bit wrong" severity failure;
    report "back-pressure ok";

    -- 5. consumer: buttons ignored, soft trigger still works
    sw <= "0010";
    wait for 1 us;
    press(0, 1 us);
    wait for 1 us;
    check_reg(16#18#, 10, "TRIG_COUNT after BTN0 on a consumer");
    axi_write(16#24#, x"00000001");
    check_event(10, ts);
    report "consumer ok";

    -- 6. clear: counters back to zero, next event is number 0 again
    axi_write(16#04#, x"00000003");
    wait for 500 ns;
    check_reg(16#18#, 0, "TRIG_COUNT after clear");
    check_reg(16#20#, 0, "DROP_COUNT after clear");
    axi_write(16#24#, x"00000001");
    check_event(0, ts);
    assert ts < 1000 report "timestamp not cleared" severity failure;
    report "clear ok";

    report "TB PASSED";
    done <= true;
    std.env.finish;       -- the MMCM model keeps running after the clocks stop
  end process;
end architecture;
