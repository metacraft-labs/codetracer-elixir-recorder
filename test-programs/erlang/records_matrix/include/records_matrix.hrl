-ifndef(RECORDS_MATRIX_HRL).
-define(RECORDS_MATRIX_HRL, true).

-define(INCLUDE_TAG, records_matrix_include_marker).
-define(INCLUDE_VERSION, 3).

-record(address, {
    city = <<"Sofia">>,
    zip = 1000
}).

-record(profile, {
    name = <<"Ada">>,
    age = 37,
    address = #address{},
    tags = [?INCLUDE_TAG]
}).

-endif.
