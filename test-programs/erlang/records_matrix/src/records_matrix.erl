-module(records_matrix).

-include("../include/records_matrix.hrl").

-export([classify/1, main/0, pattern_score/1]).

-define(LOCAL_BONUS, 17).

-record(envelope, {
    profile = #profile{},
    origin = {?MODULE, ?LOCAL_BONUS}
}).

main() ->
    ModuleMacro = ?MODULE,
    LineMacro = ?LINE,
    IncludeTag = ?INCLUDE_TAG,
    DefaultAddress = #address{},
    DefaultProfile = #profile{name = <<"Grace">>},
    AddressUpdate = DefaultAddress#address{city = <<"Varna">>, zip = 4242},
    UpdatedProfile = DefaultProfile#profile{
        age = 41 + ?INCLUDE_VERSION,
        address = AddressUpdate,
        tags = [updated | DefaultProfile#profile.tags]
    },
    ProfileName = UpdatedProfile#profile.name,
    ProfileAge = UpdatedProfile#profile.age,
    ProfileAddress = UpdatedProfile#profile.address,
    ProfileCity = ProfileAddress#address.city,
    ProfileZip = ProfileAddress#address.zip,
    #profile{name = MatchedName, address = #address{city = MatchedCity, zip = MatchedZip}} =
        UpdatedProfile,
    GuardScore = classify(UpdatedProfile),
    PatternScore = pattern_score(UpdatedProfile),
    Envelope = #envelope{profile = UpdatedProfile},
    NestedProfile = Envelope#envelope.profile,
    NestedAddress = NestedProfile#profile.address,
    NestedZip = NestedAddress#address.zip,
    ProfileFields = record_info(fields, profile),
    ProfileSize = record_info(size, profile),
    AddressFields = record_info(fields, address),
    AddressSize = record_info(size, address),
    EnvelopeFields = record_info(fields, envelope),
    EnvelopeSize = record_info(size, envelope),
    FieldsScore =
        length(ProfileFields)
        + ProfileSize
        + length(AddressFields)
        + AddressSize
        + length(EnvelopeFields)
        + EnvelopeSize,
    _UseAll = {
        ModuleMacro,
        LineMacro,
        IncludeTag,
        ProfileName,
        ProfileCity,
        MatchedName,
        MatchedCity,
        MatchedZip,
        NestedZip
    },
    Total = ProfileAge + ProfileZip + GuardScore + PatternScore + FieldsScore + ?LOCAL_BONUS,
    io:format("records-matrix-ok:~p~n", [Total]),
    ok.

classify(Profile) when is_record(Profile, profile), is_record(Profile#profile.address, address) ->
    23;
classify(_) ->
    0.

pattern_score(Profile) ->
    #profile{age = Age, address = #address{zip = Zip}} = Profile,
    true = Zip > 0,
    Age + (Zip rem 100).
