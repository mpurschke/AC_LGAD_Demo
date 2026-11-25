library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Trigger sources on the clock master:
--   btn_single: one trigger per press (rising edge of the debounced button)
--   btn_train : a trigger at the press, then one every PERIOD clocks while held
--   soft      : one-clock pulse from a register write, for tests without buttons
-- The buttons only act when allow = '1' (this board is the clock master);
-- on a consumer the triggers will come over the cable instead.
-- All inputs are synchronous to clk (buttons debounced before this block).
entity trig_gen is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    allow      : in  std_logic;
    btn_single : in  std_logic;
    btn_train  : in  std_logic;
    soft       : in  std_logic;
    period     : in  unsigned(31 downto 0);   -- clocks between train triggers, 0 is taken as 1
    trig       : out std_logic
  );
end entity;

architecture rtl of trig_gen is
  signal single_d : std_logic := '0';
  signal train_d  : std_logic := '0';
  signal cnt      : unsigned(31 downto 0) := (others => '0');
  signal trig_r   : std_logic := '0';
begin
  process (clk)
    variable t : std_logic;
  begin
    if rising_edge(clk) then
      single_d <= btn_single;
      train_d  <= btn_train;
      t := '0';

      if rst = '1' then
        cnt <= (others => '0');
      elsif btn_train = '1' and train_d = '0' then
        t := '1';                                   -- first trigger at the press
        if period > 1 then
          cnt <= period - 1;                        -- next one PERIOD clocks later
        else
          cnt <= (others => '0');
        end if;
      elsif btn_train = '1' then
        if cnt = 0 then
          t := '1';
          if period > 1 then
            cnt <= period - 1;
          end if;
        else
          cnt <= cnt - 1;
        end if;
      end if;

      if btn_single = '1' and single_d = '0' then
        t := '1';
      end if;

      trig_r <= (t and allow and not rst) or soft;
    end if;
  end process;

  trig <= trig_r;
end architecture;
