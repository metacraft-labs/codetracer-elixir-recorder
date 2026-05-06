.PHONY: compile test run clean

BUILD_DIR := _build
EBIN_DIR := $(BUILD_DIR)/ebin

compile:
	mkdir -p $(EBIN_DIR)
	erlc +debug_info -o $(EBIN_DIR) src/canonical_flow.erl

test: compile
	erlc +debug_info -I test -o $(EBIN_DIR) test/canonical_flow_tests.erl
	erl -noshell -pa $(EBIN_DIR) -eval 'case eunit:test(canonical_flow_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

run: compile
	erl -noshell -pa $(EBIN_DIR) -s canonical_flow main -s init stop

clean:
	rm -rf $(BUILD_DIR)
