LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.std_logic_textio.ALL;
USE std.textio.ALL;
USE work.utils.ALL;

ENTITY cache_data IS
	PORT(
		clk            : IN    STD_LOGIC;
		reset          : IN    STD_LOGIC;
		addr           : IN    STD_LOGIC_VECTOR(31 DOWNTO 0);
		re             : IN    STD_LOGIC;
		we             : IN    STD_LOGIC;
		data_out       : OUT   STD_LOGIC_VECTOR(31 DOWNTO 0);
		hit            : OUT   STD_LOGIC;
		done           : OUT   STD_LOGIC;
		invalid_access : OUT   STD_LOGIC;
		arb_req        : OUT   STD_LOGIC;
		arb_ack        : IN    STD_LOGIC;
		mem_cmd        : INOUT STD_LOGIC_VECTOR(2 DOWNTO 0);
		mem_addr       : INOUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		mem_done       : INOUT STD_LOGIC;
		mem_data       : INOUT STD_LOGIC_VECTOR(127 DOWNTO 0);
		repl           : OUT   STD_LOGIC;
		repl_addr      : OUT   STD_LOGIC_VECTOR(31 DOWNTO 0);
		sb_done        : IN    STD_LOGIC;
		sb_addr        : IN    STD_LOGIC_VECTOR(31 DOWNTO 0);
		sb_we          : IN    STD_LOGIC;
		sb_data_in     : IN    STD_LOGIC_VECTOR(31 DOWNTO 0)
	);
END cache_data;

ARCHITECTURE cache_data_behavior OF cache_data IS
	CONSTANT BYTE_BITS : INTEGER := 8;
	CONSTANT WORD_BITS : INTEGER := 32;

	TYPE hit_t 			IS ARRAY(3 DOWNTO 0) OF STD_LOGIC;
	TYPE lru_fields_t   IS ARRAY(3 DOWNTO 0) OF INTEGER RANGE 0 to 3;
	TYPE tag_fields_t   IS ARRAY(3 DOWNTO 0) OF STD_LOGIC_VECTOR(27 DOWNTO 0);
	TYPE data_fields_t  IS ARRAY(3 DOWNTO 0) OF STD_LOGIC_VECTOR(127 DOWNTO 0);
	TYPE valid_fields_t IS ARRAY(3 DOWNTO 0) OF STD_LOGIC;

	-- Fields of the cache
	SIGNAL lru_fields   : lru_fields_t;
	SIGNAL tag_fields   : tag_fields_t;
	SIGNAL data_fields  : data_fields_t;
	SIGNAL valid_fields : valid_fields_t;

	-- Invalid address
	SIGNAL invalid_access_i : STD_LOGIC;

	-- The next state of the cache
	SIGNAL state_i    : data_cache_state_t;
	SIGNAL state_nx_i : data_cache_state_t;

	-- Determine the line of the cache that has hit with the access
	SIGNAL hit_i : STD_LOGIC := '0';
	SIGNAL hit_line_i : hit_t;
	SIGNAL hit_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Determine the line number to output
	SIGNAL data_out_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Replacement signals
	SIGNAL repl_i : STD_LOGIC := '0';
	SIGNAL lru_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Determine the target word of the access
	SIGNAL ch_word_msb : INTEGER RANGE 0 TO 127 := 31;
	SIGNAL ch_word_lsb : INTEGER RANGE 0 TO 127 := 0;

	-- Store buffer signals
	SIGNAL sb_line_i : hit_t;
	SIGNAL sb_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Determine the target word of the SB store
	SIGNAL sb_word_msb : INTEGER RANGE 0 TO 127 := 31;
	SIGNAL sb_word_lsb : INTEGER RANGE 0 TO 127 := 0;

	-- Procedure to reset and initialize the cache
	PROCEDURE reset_cache(
			SIGNAL lru_fields : OUT lru_fields_t;
			SIGNAL valid_fields : OUT valid_fields_t;
			SIGNAL arb_req : OUT STD_LOGIC
		) IS
	BEGIN
		-- Initialize LRU and valid fields
		FOR i IN 0 TO 3 LOOP
			lru_fields(i) <= i;
			valid_fields(i) <= '0';
		END LOOP;

		arb_req <= '0';
	END PROCEDURE;

	PROCEDURE clear_bus(
			SIGNAL mem_cmd  : OUT STD_LOGIC_VECTOR(2   DOWNTO 0);
			SIGNAL mem_addr : OUT STD_LOGIC_VECTOR(31  DOWNTO 0);
			SIGNAL mem_data : OUT STD_LOGIC_VECTOR(127 DOWNTO 0);
			SIGNAL mem_done : OUT STD_LOGIC
		) IS
	BEGIN
		mem_cmd  <= (OTHERS => 'Z');
		mem_addr <= (OTHERS => 'Z');
		mem_data <= (OTHERS => 'Z');
		mem_done <= 'Z';
	END PROCEDURE;

	-- Procedure to execute the Least Recently Used alogrithm
	PROCEDURE LRU_execute(
			SIGNAL lru_fields : INOUT lru_fields_t;
			SIGNAL line_id : IN INTEGER RANGE 0 TO 3
		) IS
		VARIABLE old_value : INTEGER RANGE 0 TO 3 := lru_fields(line_id);
	BEGIN
		FOR i IN 0 TO 3 LOOP
			IF lru_fields(i) < old_value THEN
				lru_fields(i) <= lru_fields(i) + 1;
			END IF;
		lru_fields(line_id) <= 0;
		END LOOP;
	END PROCEDURE;
BEGIN

-- Process that represents the internal register
internal_register : PROCESS(clk, reset)
BEGIN
	IF rising_edge(clk) THEN
		IF reset = '1' THEN
			state_i <= READY;
		ELSE
			state_i <= state_nx_i;
		END IF;
	END IF;
END PROCESS internal_register;

-- Process that computes the next state of the cache
next_state_process : PROCESS(reset, state_i, re, we, mem_done, arb_ack, sb_done, hit_i, repl_i, invalid_access_i)
BEGIN
	IF reset = '1' THEN
		state_nx_i <= READY;
	ELSE
		state_nx_i <= state_i;
		IF state_i = READY THEN
			IF (re = '1' OR we = '1') AND invalid_access_i = '0' THEN
				IF sb_done = '0' THEN
					state_nx_i <= WAITSB;
				ELSE
					IF hit_i = '1' THEN
						state_nx_i <= READY;
					ELSE
						state_nx_i <= ARBREQ;
					END IF;
				END IF;
			END IF;

		ELSIF state_i = WAITSB THEN
			IF sb_done = '1' THEN
				IF hit_i = '1' THEN
					state_nx_i <= READY;
				ELSE
					state_nx_i <= ARBREQ;
				END IF;
			END IF;

		ELSIF state_i = ARBREQ THEN
			IF arb_ack = '1' THEN
				IF hit_i = '0' THEN
					IF repl_i = '1' THEN
						state_nx_i <= LINEREPL;
					ELSE
						state_nx_i <= LINEREQ;
					END IF;
				END IF;
			END IF;

		ELSIF state_i = LINEREPL THEN
			IF mem_done = '1' THEN
				state_nx_i <= ARBREQ;
			END IF;

		ELSIF state_i = LINEREQ THEN
			IF mem_done = '1' THEN
				state_nx_i <= READY;
			END IF;
		END IF;
	END IF;
END PROCESS next_state_process;

-- Process that sets the output signals of the cache
execution_process : PROCESS(clk)
	VARIABLE line_num : INTEGER RANGE 0 TO 3;
BEGIN
	line_num := 0;
	IF rising_edge(clk) AND reset = '1' THEN
		reset_cache(lru_fields, valid_fields, arb_req);
		clear_bus(mem_cmd, mem_addr, mem_data, mem_done);

	ELSIF falling_edge(clk) AND reset = '0' THEN
		IF state_i = READY OR state_i = WAITSB THEN
			IF state_nx_i = READY THEN
				IF re = '1' OR we = '1' THEN
					LRU_execute(lru_fields, hit_line_num_i);
					line_num := hit_line_num_i;
				END IF;
			ELSIF state_nx_i = ARBREQ THEN
				arb_req <= '1';
			END IF;
		ELSIF state_i = ARBREQ THEN
			IF state_nx_i = LINEREPL THEN
				mem_cmd <= CMD_PUT;
				mem_addr <= tag_fields(lru_line_num_i) & "0000";
				mem_data <= data_fields(lru_line_num_i);
			ELSIF state_nx_i = LINEREQ THEN
				mem_cmd <= CMD_GET;
				mem_addr <= addr;
			END IF;
		ELSIF state_i = LINEREPL THEN
			IF state_nx_i = ARBREQ THEN
				arb_req <= '1';
				clear_bus(mem_cmd, mem_addr, mem_data, mem_done);
			END IF;
		ELSIF state_i = LINEREQ THEN
			IF state_nx_i = READY THEN
				arb_req <= '0';
				valid_fields(lru_line_num_i) <= '1';
				tag_fields(lru_line_num_i) <= addr(31 DOWNTO 4);
				data_fields(lru_line_num_i) <= mem_data;
				LRU_execute(lru_fields, lru_line_num_i);
				clear_bus(mem_cmd, mem_addr, mem_data, mem_done);
				line_num := lru_line_num_i;
			END IF;
		END IF;

		IF sb_we = '1' THEN
			data_fields(sb_line_num_i)(sb_word_msb DOWNTO sb_word_lsb) <= sb_data_in;
		END IF;

		data_out_line_num_i <= line_num;
	END IF;
END PROCESS execution_process;

-- Check if the access is invalid
invalid_access <= invalid_access_i;
invalid_access_i <= '1' WHEN (re = '1' OR we = '1') AND addr(1 DOWNTO 0) /= "00" ELSE '0';

-- For each line, determine if the access has hit
hit_line_i(0) <= valid_fields(0) AND to_std_logic(tag_fields(0) = addr(31 DOWNTO 4));
hit_line_i(1) <= valid_fields(1) AND to_std_logic(tag_fields(1) = addr(31 DOWNTO 4));
hit_line_i(2) <= valid_fields(2) AND to_std_logic(tag_fields(2) = addr(31 DOWNTO 4));
hit_line_i(3) <= valid_fields(3) AND to_std_logic(tag_fields(3) = addr(31 DOWNTO 4));

-- Determine which line has hit
hit_line_num_i <= 0 WHEN hit_line_i(0) = '1'
		ELSE 1 WHEN hit_line_i(1) = '1'
		ELSE 2 WHEN hit_line_i(2) = '1'
		ELSE 3 WHEN hit_line_i(3) = '1'
		ELSE 0;

-- Determine if the access has hit
hit <= hit_i;
hit_i <= hit_line_i(0) OR hit_line_i(1) OR hit_line_i(2) OR hit_line_i(3);

-- Determine the least recently used line
lru_line_num_i <= 0 WHEN lru_fields(0) = 3
		ELSE 1 WHEN lru_fields(1) = 3
		ELSE 2 WHEN lru_fields(2) = 3
		ELSE 3 WHEN lru_fields(3) = 3
		ELSE 0;

sb_line_i(0) <= valid_fields(0) AND to_std_logic(tag_fields(0) = sb_addr(31 DOWNTO 4));
sb_line_i(1) <= valid_fields(1) AND to_std_logic(tag_fields(1) = sb_addr(31 DOWNTO 4));
sb_line_i(2) <= valid_fields(2) AND to_std_logic(tag_fields(2) = sb_addr(31 DOWNTO 4));
sb_line_i(3) <= valid_fields(3) AND to_std_logic(tag_fields(3) = sb_addr(31 DOWNTO 4));

sb_line_num_i <= 0 WHEN sb_line_i(0) = '1'
		ELSE 1 WHEN sb_line_i(1) = '1'
		ELSE 2 WHEN sb_line_i(2) = '1'
		ELSE 3 WHEN sb_line_i(3) = '1'
		ELSE 0;

-- Determine if a replacement is needed
repl <= repl_i;
repl_i <= NOT hit_i AND valid_fields(0) AND valid_fields(1) AND valid_fields(2) AND valid_fields(3);
repl_addr <= tag_fields(lru_line_num_i) & "0000";

-- The cache stalls when there is a cache operation that misses
done <= hit_i OR NOT(re OR we);

-- Store buffer logic
sb_word_msb <= (to_integer(unsigned(sb_addr(3 DOWNTO 2))) + 1) * WORD_BITS - 1;
sb_word_lsb <= to_integer(unsigned(sb_addr(3 DOWNTO 2))) * WORD_BITS;

-- Output Data logic
ch_word_msb <= (to_integer(unsigned(addr(3 DOWNTO 2))) + 1) * WORD_BITS - 1;
ch_word_lsb <= to_integer(unsigned(addr(3 DOWNTO 2))) * WORD_BITS;
data_out <= data_fields(data_out_line_num_i)(ch_word_msb DOWNTO ch_word_lsb);

END cache_data_behavior;
