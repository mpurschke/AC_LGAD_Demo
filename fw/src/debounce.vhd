library ieee;
use ieee.std_logic_1164.all;

-- Debouncer for buttons and switches: 2-flop synchronizer, then sample every
-- TICK clocks; the output takes a new level only after STABLE equal samples.
-- At 250 MHz, TICK = 250_000 and STABLE = 8 give ~1 ms sampling, ~8 ms filter.
entity debounce is
  generic (
    N      : positive := 1;
    TICK   : positive := 250_000;
    STABLE : positive := 8
  );
  port (
    clk  : in  std_logic;
    din  : in  std_logic_vector(N-1 downto 0);    -- async
    dout : out std_logic_vector(N-1 downto 0)     -- sync to clk
  );
end entity;

architecture rtl of debounce is
  signal s1, s2 : std_logic_vector(N-1 downto 0) := (others => '0');
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of s1, s2 : signal is "TRUE";

  signal tick_cnt : natural range 0 to TICK-1 := 0;
  signal sample   : std_logic := '0';

  type hist_t is array (0 to N-1) of std_logic_vector(STABLE-1 downto 0);
  signal hist : hist_t := (others => (others => '0'));
  signal q    : std_logic_vector(N-1 downto 0) := (others => '0');

  constant ONES  : std_logic_vector(STABLE-1 downto 0) := (others => '1');
  constant ZEROS : std_logic_vector(STABLE-1 downto 0) := (others => '0');
begin
  process (clk)
  begin
    if rising_edge(clk) then
      s1 <= din;  s2 <= s1;

      sample <= '0';
      if tick_cnt = TICK-1 then
        tick_cnt <= 0;
        sample   <= '1';
      else
        tick_cnt <= tick_cnt + 1;
      end if;

      if sample = '1' then
        for i in 0 to N-1 loop
          hist(i) <= hist(i)(STABLE-2 downto 0) & s2(i);
          if hist(i) = ONES then
            q(i) <= '1';
          elsif hist(i) = ZEROS then
            q(i) <= '0';
          end if;
        end loop;
      end if;
    end if;
  end process;

  dout <= q;
end architecture;
