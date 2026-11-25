library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Timestamp counter and event builder, all on the shared clock.
--
-- 64-bit timestamp, zeroed by clear (later by SYNC from the clock master).
-- Each trigger while enabled gets the next trigger number. If the builder is
-- free, the trigger becomes an event on the AXI-Stream output; if it is still
-- sending the previous event (or the FIFO behind it is full), the trigger is
-- dropped and counted. The trigger logic itself never waits.
--
-- The packet counter is the trigger number, so a dropped trigger leaves a gap
-- and events from two boards with the same number belong to the same trigger.
--
-- Event, 7 words of 32 bit (TLAST on the last one), little-endian as seen by the PS:
--   0: length of the event in bytes (28)
--   1: timestamp bits 31..0
--   2: timestamp bits 63..32
--   3: packet counter (trigger number)
--   4: 0xFEEDC0DE
--   5: 0xDECAFBAD
--   6: 0xF0F0F0F0
entity evt_gen is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    clear      : in  std_logic;                   -- zero timestamp, numbers, counters
    enable     : in  std_logic;
    trig       : in  std_logic;

    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    trig_count : out unsigned(31 downto 0);       -- triggers while enabled
    evt_count  : out unsigned(31 downto 0);       -- events sent
    drop_count : out unsigned(31 downto 0);       -- triggers dropped
    dropped    : out std_logic                    -- sticky: a drop happened since clear
  );
end entity;

architecture rtl of evt_gen is
  signal ts        : unsigned(63 downto 0) := (others => '0');
  signal trig_cnt  : unsigned(31 downto 0) := (others => '0');
  signal evt_cnt   : unsigned(31 downto 0) := (others => '0');
  signal drop_cnt  : unsigned(31 downto 0) := (others => '0');
  signal drop_any  : std_logic := '0';

  constant LAST_W : natural := 6;
  signal sending : std_logic := '0';
  signal widx    : natural range 0 to LAST_W := 0;   -- word index in the event

  -- values latched at the trigger
  signal l_ts    : unsigned(63 downto 0) := (others => '0');
  signal l_num   : unsigned(31 downto 0) := (others => '0');

  signal tlast : std_logic;
begin
  tlast <= '1' when widx = LAST_W else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or clear = '1' then
        ts        <= (others => '0');
        trig_cnt  <= (others => '0');
        evt_cnt   <= (others => '0');
        drop_cnt  <= (others => '0');
        drop_any  <= '0';
        sending   <= '0';
        widx      <= 0;
      else
        ts <= ts + 1;

        -- send the current event
        if sending = '1' and m_axis_tready = '1' then
          if tlast = '1' then
            sending <= '0';
            evt_cnt <= evt_cnt + 1;
          else
            widx <= widx + 1;
          end if;
        end if;

        -- a new trigger
        if trig = '1' and enable = '1' then
          trig_cnt <= trig_cnt + 1;
          if sending = '0' then
            sending <= '1';
            widx    <= 0;
            l_ts    <= ts;
            l_num   <= trig_cnt;
          else
            drop_cnt <= drop_cnt + 1;
            drop_any <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  with widx select m_axis_tdata <=
    std_logic_vector(to_unsigned(4 * (LAST_W + 1), 32)) when 0,
    std_logic_vector(l_ts(31 downto 0))                 when 1,
    std_logic_vector(l_ts(63 downto 32))                when 2,
    std_logic_vector(l_num)                             when 3,
    x"FEEDC0DE"                                         when 4,
    x"DECAFBAD"                                         when 5,
    x"F0F0F0F0"                                         when others;

  m_axis_tvalid <= sending;
  m_axis_tlast  <= tlast;

  trig_count <= trig_cnt;
  evt_count  <= evt_cnt;
  drop_count <= drop_cnt;
  dropped    <= drop_any;
end architecture;
