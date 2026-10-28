# Task 8.5 standalone probe clock.  This is not a final-top timing claim.
create_clock -name clk_test_mode -period 10.000 [get_ports {clk}]
