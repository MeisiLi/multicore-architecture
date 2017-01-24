LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;
USE ieee.std_logic_textio.ALL;
USE std.textio.ALL;
USE work.utils.ALL;

ENTITY cache_tags IS
	PORT(
		clk            : IN  STD_LOGIC;
		reset          : IN  STD_LOGIC;
		debug_dump     : IN  STD_LOGIC;
		addr           : IN  STD_LOGIC_VECTOR(31 DOWNTO 0);
		re             : IN  STD_LOGIC;
		we             : IN  STD_LOGIC;
		is_byte        : IN  STD_LOGIC;
		done           : OUT STD_LOGIC;
		hit            : OUT STD_LOGIC;
		line_num       : OUT INTEGER RANGE 0 TO 3;
		line_we        : OUT STD_LOGIC;
		lru_line_num   : OUT INTEGER RANGE 0 TO 3;
		invalid_access : OUT STD_LOGIC;
		mem_req        : OUT STD_LOGIC;
		mem_addr       : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		mem_we         : OUT STD_LOGIC;
		mem_done       : IN  STD_LOGIC;
		repl           : OUT STD_LOGIC;
		repl_addr      : OUT STD_LOGIC_VECTOR(31 DOWNTO 0);
		sb_done        : IN STD_LOGIC;
		sb_addr        : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
		sb_we          : IN STD_LOGIC
	);
END cache_tags;

ARCHITECTURE cache_tags_behavior OF cache_tags IS
	TYPE lru_fields_t   IS ARRAY(3 DOWNTO 0) OF INTEGER RANGE 0 to 3;
	TYPE valid_fields_t IS ARRAY(3 DOWNTO 0) OF STD_LOGIC;
	TYPE dirty_fields_t IS ARRAY(3 DOWNTO 0) OF STD_LOGIC;
	TYPE tag_fields_t   IS ARRAY(3 DOWNTO 0) OF STD_LOGIC_VECTOR(27 DOWNTO 0);

	TYPE hit_t IS ARRAY(3 DOWNTO 0) OF STD_LOGIC;

	-- Fields of the cache
	SIGNAL lru_fields   : lru_fields_t;
	SIGNAL valid_fields : valid_fields_t;
	SIGNAL dirty_fields : dirty_fields_t;
	SIGNAL tag_fields   : tag_fields_t;

	-- Invalid address
	SIGNAL invalid_access_i : STD_LOGIC;

	-- The next state of the cache
	SIGNAL state_i : data_cache_state_t;
	SIGNAL state_nx_i : data_cache_state_t;

	-- Determine the line of the cache that has hit with the access
	SIGNAL hit_i : STD_LOGIC := '0';
	SIGNAL hit_line_i : hit_t;
	SIGNAL hit_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Replacement signals
	SIGNAL repl_i : STD_LOGIC := '0';
	SIGNAL repl_dirty_i : STD_LOGIC := '0';
	SIGNAL lru_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Store buffer signals
	SIGNAL sb_line_i : hit_t;
	SIGNAL sb_line_num_i : INTEGER RANGE 0 TO 3 := 0;

	-- Procedure to reset and initialize the cache
	PROCEDURE reset_cache(
			SIGNAL lru_fields : OUT lru_fields_t;
			SIGNAL valid_fields : OUT valid_fields_t;
			SIGNAL dirty_fields : OUT dirty_fields_t;
			SIGNAL mem_req : OUT STD_LOGIC
		) IS
	BEGIN
		-- Initialize LRU and valid fields
		FOR i IN 0 TO 3 LOOP
			lru_fields(i) <= i;
			valid_fields(i) <= '0';
			dirty_fields(i) <= '0';
		END LOOP;

		-- Cancel any memory request
		mem_req <= '0';
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

	PROCEDURE dump_cache_tags(CONSTANT filename : IN STRING;
						SIGNAL cache_valid : IN valid_fields_t;
						SIGNAL cache_tags : IN tag_fields_t) IS
		FILE dumpfile : TEXT OPEN write_mode IS filename;
		VARIABLE lbuf : LINE;
		VARIABLE dummy_tag : STD_LOGIC_VECTOR(27 DOWNTO 0) := (OTHERS => 'X');
	BEGIN
		FOR n_line IN 0 TO 3 LOOP
			IF cache_valid(n_line) = '1' THEN
				-- Hex convert
				hwrite(lbuf, cache_tags(n_line));
			ELSE
				hwrite(lbuf, dummy_tag);
			END IF;
			-- Write to file
			writeline(dumpfile, lbuf);
		END LOOP;
	END PROCEDURE;
BEGIN

internal_reg_process : PROCESS(clk, reset)
BEGIN
	IF rising_edge(clk) THEN
		IF reset = '1' THEN
			state_i <= READY;
		ELSE
			state_i <= state_nx_i;
		END IF;
	END IF;
END PROCESS internal_reg_process;

-- Process that computes the next state of the cache
next_state_process : PROCESS(reset, state_i, re, we, sb_done, invalid_access_i, hit_i, repl_dirty_i, mem_done)
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
					ELSIF repl_dirty_i = '1' THEN
						state_nx_i <= LINEREPL;
					ELSE
						state_nx_i <= LINEREQ;
					END IF;
				END IF;
			END IF;
		ELSIF state_i = WAITSB THEN
			IF sb_done = '1' THEN
				IF hit_i = '1' THEN
					state_nx_i <= READY;
				ELSIF repl_dirty_i = '1' THEN
					state_nx_i <= LINEREPL;
				ELSE
					state_nx_i <= LINEREQ;
				END IF;
			END IF;

		ELSIF state_i = LINEREPL THEN
			IF mem_done = '1' THEN
				state_nx_i <= LINEREQ;
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
BEGIN
	IF rising_edge(clk) AND reset = '1' THEN
		reset_cache(lru_fields, valid_fields, dirty_fields, mem_req);

	ELSIF falling_edge(clk) AND reset = '0' THEN
		IF debug_dump = '1' THEN
			dump_cache_tags("dump/cache_d_tags", valid_fields, tag_fields);
		END IF;

		IF state_i = READY OR state_i = WAITSB THEN
			IF state_nx_i = READY THEN
				IF re = '1' OR we = '1' THEN
					line_num <= hit_line_num_i;
					LRU_execute(lru_fields, hit_line_num_i);
				END IF;
			ELSIF state_nx_i = LINEREPL THEN
				mem_req <= '1';
				mem_we <= '1';
				mem_addr <= tag_fields(lru_line_num_i) & "0000";
			ELSIF state_nx_i = LINEREQ THEN
				mem_req <= '1';
				mem_we <= '0';
				mem_addr <= addr;
			END IF;
		ELSIF state_i = LINEREPL THEN
			IF state_nx_i = LINEREQ THEN
				mem_req <= '1';
				mem_we <= '0';
				mem_addr <= addr;
			END IF;
		ELSIF state_i = LINEREQ THEN
			IF state_nx_i = READY THEN
				mem_req <= '0';
				line_num <= lru_line_num_i;
				valid_fields(lru_line_num_i) <= '1';
				dirty_fields(lru_line_num_i) <= '0';
				tag_fields(lru_line_num_i) <= addr(31 DOWNTO 4);
				LRU_execute(lru_fields, lru_line_num_i);
			END IF;
		END IF;

		IF sb_we = '1' THEN
			line_num <= sb_line_num_i;
			dirty_fields(sb_line_num_i) <= '1';
		END IF;
	END IF;
END PROCESS execution_process;

-- Check if the access is invalid
invalid_access_i <= '1' WHEN (re = '1' OR we = '1') AND is_byte = '0' AND addr(1 DOWNTO 0) /= "00" ELSE '0';

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
repl_i <= NOT hit_i AND valid_fields(0) AND valid_fields(1) AND valid_fields(2) AND valid_fields(3);
repl_addr <= tag_fields(lru_line_num_i) & "0000";
repl <= repl_i;

-- Determine if the replaced line is dirty
repl_dirty_i <= repl_i AND dirty_fields(lru_line_num_i);

-- The cache has not finished only when a access produces a miss
done <= hit_i OR NOT(re OR we);

-- Output signals to send new lines to the data cache
line_we <= '1' WHEN state_i = LINEREQ AND state_nx_i = READY ELSE '0';

-- Other output signals
hit <= hit_i;
lru_line_num <= lru_line_num_i;
invalid_access <= invalid_access_i;

END cache_tags_behavior;
