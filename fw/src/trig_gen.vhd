library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Trigger sources on the clock master:
--   btn_single : one trigger per press (rising edge of the debounced button)
--   btn_train  : a trigger at the press, then one every TRAIN clocks while held
--   ext_in     : hardware trigger from a Pmod pin (asynchronous), one per rising edge,
--                8 ns resolution, 3 clocks latency (2 synchronizer stages + edge)
--   pulser     : one trigger every PULSE clocks while enabled
--   soft       : one-clock pulse from a register write, for tests
-- src_mask selects the sources: bit0 buttons, bit1 ext_in, bit2 pulser.
-- Buttons, ext_in and the pulser only act when allow = '1' (this board is the
-- clock master); on a consumer the triggers will come over the cable instead.
-- The soft trigger always works.
entity trig_gen is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    allow        : in  std_logic;
    src_mask     : in  std_logic_vector(2 downto 0);
    btn_single   : in  std_logic;                 -- debounced, synchronous
    btn_train    : in  std_logic;                 -- debounced, synchronous
    ext_in       : in  std_logic;                 -- asynchronous, from the pad
    soft         : in  std_logic;
    train_period : in  unsigned(31 downto 0);     -- clocks, 0 is taken as 1
    pulse_period : in  unsigned(31 downto 0);     -- clocks, 0 is taken as 1
    trig         : out std_logic
  );
end entity;

architecture rtl of trig_gen is
  signal single_d : std_logic := '0';
  signal train_d  : std_logic := '0';
  signal cnt      : unsigned(31 downto 0) := (others => '0');
  signal pcnt     : unsigned(31 downto 0) := (others => '0');
  signal pulse_on : std_logic := '0';
  signal trig_r   : std_logic := '0';

  signal e1, e2, e3 : std_logic := '0';
  attribute ASYNC_REG : string;
  attribute ASYNC_REG of e1, e2 : signal is "TRUE";
  attribute IOB : string;
  attribute IOB of e1 : signal is "TRUE";
begin
  process (clk)
    variable t_btn, t_pls : std_logic;
  begin
    if rising_edge(clk) then
      single_d <= btn_single;
      train_d  <= btn_train;
      e1 <= ext_in;  e2 <= e1;  e3 <= e2;
      t_btn := '0';
      t_pls := '0';

      -- BTN1 train
      if rst = '1' then
        cnt <= (others => '0');
      elsif btn_train = '1' and train_d = '0' then
        t_btn := '1';                               -- first trigger at the press
        if train_period > 1 then
          cnt <= train_period - 1;                  -- next one TRAIN clocks later
        else
          cnt <= (others => '0');
        end if;
      elsif btn_train = '1' then
        if cnt = 0 then
          t_btn := '1';
          if train_period > 1 then
            cnt <= train_period - 1;
          end if;
        else
          cnt <= cnt - 1;
        end if;
      end if;

      if btn_single = '1' and single_d = '0' then
        t_btn := '1';
      end if;

      -- pulser: the first trigger one period after it is switched on
      pulse_on <= src_mask(2) and allow;
      if rst = '1' or pulse_on = '0' then
        if pulse_period > 1 then
          pcnt <= pulse_period - 1;
        else
          pcnt <= (others => '0');
        end if;
      elsif pcnt = 0 then
        t_pls := '1';
        if pulse_period > 1 then
          pcnt <= pulse_period - 1;
        end if;
      else
        pcnt <= pcnt - 1;
      end if;

      trig_r <= (allow and not rst and
                 ((t_btn and src_mask(0)) or (e2 and not e3 and src_mask(1)) or t_pls))
                or soft;
    end if;
  end process;

  trig <= trig_r;
end architecture;
