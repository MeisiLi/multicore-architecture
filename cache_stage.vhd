LIBRARY ieee;
USE ieee.std_logic_1164.all;
USE ieee.numeric_std.all;
USE work.utils.all;

ENTITY cache_stage IS
	PORT(
		clk          : IN STD_LOGIC;
		reset        : IN STD_LOGIC;
		debug_dump   : IN STD_LOGIC;
		addr         : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
		data_in      : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
		data_out     : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		mux_data_out : IN STD_LOGIC;
		we           : IN STD_LOGIC;
		is_byte      : IN STD_LOGIC;
		line_num     : IN INTEGER RANGE 0 TO 3;
		line_we      : IN STD_LOGIC;
		line_data    : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
		lru_line_num : IN INTEGER RANGE 0 TO 3;
		mem_data_out : OUT STD_LOGIC_VECTOR(127 DOWNTO 0)
	);
END cache_stage;

ARCHITECTURE cache_stage_behavior OF cache_stage IS
	COMPONENT cache_data IS
		PORT(
			clk          : IN STD_LOGIC;
			reset        : IN STD_LOGIC;
			debug_dump   : IN STD_LOGIC;
			addr         : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
			data_in      : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
			data_out     : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
			we           : IN STD_LOGIC;
			is_byte      : IN STD_LOGIC;
			line_num     : IN INTEGER RANGE 0 TO 3;
			line_we      : IN STD_LOGIC;
			line_data    : IN STD_LOGIC_VECTOR(127 DOWNTO 0);
			lru_line_num : IN INTEGER RANGE 0 TO 3;
			mem_data_out : OUT STD_LOGIC_VECTOR(127 DOWNTO 0)
		);
	END COMPONENT;

	SIGNAL cache_data_out : STD_LOGIC_VECTOR(31 DOWNTO 0);

BEGIN
	cache : cache_data PORT MAP(
		clk => clk,
		reset => reset,
		debug_dump => debug_dump,
		addr => addr,
		data_in => data_in,
		data_out => cache_data_out,
		we => we,
		is_byte => is_byte,
		line_num => line_num,
		line_we => line_we,
		line_data => line_data,
		lru_line_num => lru_line_num,
		mem_data_out => mem_data_out);

	data_out <= data_in WHEN mux_data_out = '1' ELSE cache_data_out;

END cache_stage_behavior;
