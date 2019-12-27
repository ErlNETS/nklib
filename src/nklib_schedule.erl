%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NetComposer Standard Library
-module(nklib_schedule).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([next_fire_time/3, next_fire_time2/3]).
-export([parse/1, get_dates/3]).
-export([all_tests/0]).

%% ===================================================================
%% Types
%% ===================================================================


-type params() ::
    #{
        repeat => daily | weekly | monthly,
        hour := 0..23,
        minute := 0..59,
        second => 0..59,
        timezone => binary(),
        daily_week_days => [0..6],
        daily_step_days => 1..25,
        weekly_day => 0..6,
        monthly_day => 0..28 | last,
        start_date => binary,
        stop_date => binary
    }.

-type status() ::
    #{
        last_fire_time => binary
    }.



%% ===================================================================
%% API
%% ===================================================================


-spec next_fire_time(integer()|binary(), params(), status()) ->
    binary().

next_fire_time(Now, Params, Status) ->
    case parse(Params) of
        {ok, Params2} ->
            case nklib_date:to_3339(Now, secs) of
                {ok, Now2} ->
                    next_fire_time2(Now2, Params2, Status);
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.



-spec get_dates(integer()|binary(), pos_integer(), params()) ->
    [binary()].

get_dates(Start, Num, Params) ->
    get_dates(Start, Num, Params, #{}, []).


%% @doc
parse(Params) ->
    Base = #{
        repeat => {atom, [daily, weekly, monthly]},
        hour => {integer, 0, 23},
        minute => {integer, 0, 59},
        second => {integer, 0, 59},
        timezone => fun nklib_date:syntax_timezone/1,
        daily_week_days => {list, {integer, 0, 6}},
        daily_step_days => {integer, 1, 25},
        weekly_day => {integer, 0, 6},
        monthly_day => [{integer, 0, 28}, {atom, [last]}],
        start_date => date_3339,
        stop_date => date_3339,
        '__mandatory' => [repeat],
        '__defaults' => #{
            hour => 12,
            minute => 0,
            timezone => <<"GMT">>
        }
    },
    case nklib_syntax:parse(Params, Base) of
        {ok, #{repeat:=Repeat}=Parsed, _} ->
            case Repeat of
                daily ->
                    {ok, Parsed};
                weekly ->
                    case maps:is_key(weekly_day, Parsed) of
                        true ->
                            {ok, Parsed};
                        false ->
                            case maps:find(start_date, Params) of
                                {ok, StartDate} ->
                                    WD = get_date_day_of_week(StartDate),
                                    {ok, Parsed#{weekly_day => WD}};
                                error ->
                                    {error, {field_missing, weekly_day}}
                            end
                    end;
                monthly ->
                    case maps:is_key(monthly_day, Parsed) of
                        true ->
                            {ok, Parsed};
                        false ->
                            case maps:find(start_date, Params) of
                                {ok, StartDate} ->
                                    MD = get_date_day_of_month(StartDate),
                                    {ok, Parsed#{monthly_day => MD}};
                                error ->
                                    {error, {field_missing, weekly_day}}
                            end
                    end
            end;
        {error, Error} ->
            {error, Error}
    end.


-spec next_fire_time2(integer(), params(), status()) ->
    binary().

next_fire_time2(Now, #{repeat:=daily}=Params, Status) ->
    {{ZoneNowDate, ZoneNowTime}, FireTime} = get_times(Now, Params),
    case ZoneNowTime < FireTime of
        true ->
            % The hour is still valid for today
            Fire = {ZoneNowDate, FireTime},
            make_gmt(Fire, Params, Status);
        false ->
            % Already passed, set it for tomorrow
            NowDate2 = add_days(ZoneNowDate, 1),
            Date3 = date_to_3339(NowDate2),
            next_fire_time2(Date3, Params, Status)
    end;

next_fire_time2(Now, #{repeat:=weekly}=Params, Status) ->
    {{ZoneNowDate, ZoneNowTime}, FireTime} = get_times(Now, Params),
    WeeklyDay = maps:get(weekly_day, Params),
    true = WeeklyDay >= 0 andalso WeeklyDay =< 6,
    case get_weekly_day(ZoneNowDate) of
        WeeklyDay when ZoneNowTime < FireTime ->
            Fire = {ZoneNowDate, FireTime},
            make_gmt(Fire, Params, Status);
        WeeklyDay ->
            NowDate2 = add_days(ZoneNowDate, 1),
            Date3 = date_to_3339(NowDate2),
            next_fire_time2(Date3, Params, Status);
        _ ->
            % Let's jump to the correct week day
            NowDate3 = next_weekly_date(WeeklyDay, ZoneNowDate),
            Date4 = date_to_3339(NowDate3),
            next_fire_time2(Date4, Params, Status)
    end;

next_fire_time2(Now, #{repeat:=monthly}=Params, Status) ->
    {{ZoneNowDate, ZoneNowTime}, FireTime} = get_times(Now, Params),
    {NowY, NowM, NowD} = ZoneNowDate,
    MonthlyDay1 = maps:get(monthly_day, Params),
    MonthlyDay2 = case MonthlyDay1 of
        last ->
            calendar:last_day_of_the_month(NowY, NowM);
        MD when is_integer(MD) andalso MD >= 1 andalso MD =< 28 ->
            MD
    end,
    case NowD of
        MonthlyDay2 when ZoneNowTime < FireTime ->
            Fire = {ZoneNowDate, FireTime},
            make_gmt(Fire, Params, Status);
        MonthlyDay2 ->
            NowDate2 = add_days(ZoneNowDate, 1),
            Date3 = date_to_3339(NowDate2),
            next_fire_time2(Date3, Params, Status);
        _ ->
            NowDate3 = next_monthly_date(MonthlyDay1, ZoneNowDate),
            Date4 = date_to_3339(NowDate3),
            next_fire_time2(Date4, Params, Status)
    end.



%% ===================================================================
%% Internal
%% ===================================================================

%% @private
get_dates(Start, Num, Params, Status, Acc) when Num > 0 ->
    case next_fire_time(Start, Params, Status) of
        <<>> ->
            lists:reverse(Acc);
        Fire ->
            get_dates(Fire, Num-1, Params, Status#{last_fire_time=>Fire}, [Fire|Acc])
    end;

get_dates(_Start, _Num, _Params, _Status, Acc) ->
    lists:reverse(Acc).


%% @private
get_times(NowDate, Params) ->
    TZ = maps:get(timezone, Params, <<"GMT">>),
    NowDate2 = case Params of
        #{start_date:=StartDate} ->
            {ok, ND2} = nklib_date:to_3339(NowDate, secs),
            case StartDate > ND2 of
                true ->
                    ND2;
                _ ->
                    NowDate
            end;
        _ ->
            NowDate
    end,
    Sec = case Params of
        #{second:=S} ->
            S;
        _ ->
            erlang:phash2(nklib_date:epoch(usecs)) rem 60
    end,
    qdate_srv:set_timezone("GMT"),
    % From GMT to Zone
    #{hour:=H, minute:=M} = Params,
    % Do not allow FireTime to be {0,0,0} so that recurring times set as {0, 0, 0}
    % are always lower than any possible configured fire time
    FireTime = case {H, M, Sec} of
        {0, 0, 0} ->
            {0, 0, 1};
        _ ->
            {H, M, Sec}
    end,
    {qdate:to_date(TZ, NowDate2), FireTime}.


%% @private
make_gmt(Fire, Params, Status) ->
    TZ = maps:get(timezone, Params, <<"GMT">>),
    qdate_srv:set_timezone(TZ),
    FireGmt1 = qdate:to_date("GMT", Fire),
    FireGmt2 = check_step_days(FireGmt1, Params, Status),
    FireGmt3 = check_week_days(FireGmt2, Params),
    FireGmt4 =  nklib_util:gmt_to_timestamp(FireGmt3),
    {ok, FireGmt5} = nklib_date:to_3339(FireGmt4*1000000+1, usecs),
    case Params of
        #{stop_date:=StopDate} when FireGmt5 > StopDate ->
            <<>>;
        _ ->
            FireGmt5
    end.


%% @private
check_step_days({Date, Time}, #{repeat:=daily, daily_step_days:=Days}, Status)
    when Days > 1 ->
    case Status of
        #{last_fire_time:=Fire1} ->
            {ok, Fire2} = nklib_date:to_epoch(Fire1, secs),
            {Fire3, _} = calendar:now_to_universal_time({0, Fire2, 0}),
            Diff =
                calendar:date_to_gregorian_days(Date) -
                    calendar:date_to_gregorian_days(Fire3),
            Add = Days - Diff,
            case Add > 0 of
                true ->
                    {add_days(Date, Add), Time};
                false ->
                    {Date, Time}
            end;
        _ ->
            {Date, Time}
    end;

check_step_days({Date, Time}, _Params, _Status) ->
    {Date, Time}.


%% @private
check_week_days(Date, #{repeat:=daily, daily_week_days:=Days}) when length(Days) > 0 ->
    check_week_days(Date, Days, 7);

check_week_days(Date, _Params) ->
    Date.


%% @private
check_week_days({Date, Time}, Days, Rem) when Rem > 0 ->
    WD = get_weekly_day(Date),
    case lists:member(WD, Days) of
        true ->
            {Date, Time};
        false ->
            Date2 = add_days(Date, 1),
            check_week_days({Date2, Time}, Days, Rem-1)
    end;

check_week_days(_Date, Days, _Rem) ->
    error({days_week_days_invalid, Days}).


%% @private
add_days(Date, Days) ->
    calendar:gregorian_days_to_date(calendar:date_to_gregorian_days(Date)+Days).

%% @private
next_weekly_date(WD, Date) ->
    DateWD = get_weekly_day(Date),
    AddDays = case WD - DateWD of
        Days when Days >= 0 -> Days;
        NegDays -> 7 + NegDays
    end,
    Date2 = add_days(Date, AddDays),
    WD = get_weekly_day(Date2),    % Check
    Date2.


%% @private
get_weekly_day(Date) ->
    case calendar:day_of_the_week(Date) of
        7 -> 0;
        O -> O
    end.


%% @private
next_monthly_date(MD, {DateY, DateM, DateD}=Date) ->
    MD2 = case MD of
        last ->
            calendar:last_day_of_the_month(DateY, DateM);
        MD0 when is_integer(MD0), MD0 >= 1, MD0 =< 28 ->
            MD0
    end,
    case MD2 - DateD of
        0 ->
            Date;
        Days when Days > 0 ->
            add_days(Date, Days);
        _ ->
            Date2 = add_month({DateY, DateM, 1}),
            next_monthly_date(MD, Date2)
    end.


%% @private
add_month({Y, M, D}) ->
    {Y2, M2} = case M+1 of
        13 ->
            {Y+1, 1};
        _ ->
            {Y, M+1}
    end,
    fix_month({Y2, M2, D}).

fix_month({Y, M, D}) ->
    Last = calendar:last_day_of_the_month(Y, M),
    D2 = case D > Last of
        true -> Last;
        false -> D
    end,
    {Y, M, D2}.


%% @private
date_to_3339(Date) ->
    Date2 = nklib_util:gmt_to_timestamp({Date, {0, 0, 0}}),
    {ok, Date3} = nklib_date:to_3339(Date2, secs),
    Date3.


%% @private
get_date_day_of_week(Date) ->
    {ok, Date2} = nklib_date:to_epoch(Date, secs),
    {Date3, _} = calendar:now_to_universal_time({0, Date2, 0}),
    get_weekly_day(Date3).


%% @private
get_date_day_of_month(Date) ->
    {ok, Date2} = nklib_date:to_epoch(Date, secs),
    {{_, _, Day}, _} = calendar:now_to_universal_time({0, Date2, 0}),
    Day.



%% ===================================================================
%% Tests
%% ===================================================================

all_tests() ->
    daily1_test(),
    daily2_test(),
    weekly1_test(),
    weekly2_test(),
    monthly1_test(),
    monthly2_test(),
    ok.


daily1_test() ->
    %% 11:50 GMT in Madrid is 12:50
    {ok, Now1} = nklib_date:to_epoch("2019-12-23T11:50:09Z", secs),
    P1 = #{
        repeat => daily,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10
    },
    % Still fire today
    <<"2019-12-23T11:50:10.000001Z">> = next_fire_time(Now1, P1, #{}),

    % Two seconds later, is already for tomorrow
    {ok, Now2} = nklib_date:to_epoch("2019-12-23T11:50:11Z", secs),
    <<"2019-12-24T11:50:10.000001Z">> = next_fire_time(Now2, P1, #{}),

    % Lets set for sundays, mondays and saturdays
    P2 = P1#{daily_week_days=>[0, 1, 6]},
    % 23 is monday, so ok
    <<"2019-12-23T11:50:10.000001Z">> = next_fire_time(Now1, P2, #{}),
    % It wraps to 24 (tuesday) so will jump to saturday
    <<"2019-12-28T11:50:10.000001Z">> = next_fire_time(Now2, P2, #{}),
    Now3 = <<"2019-12-28T11:50:12.000001Z">>,
    % Next is sunday, ok
    <<"2019-12-29T11:50:10.000001Z">> = next_fire_time(Now3, P2, #{}),
    Now4 = <<"2019-12-29T11:50:12.000001Z">>,
    % Next is monday, ok
    <<"2019-12-30T11:50:10.000001Z">> = next_fire_time(Now4, P2, #{}),
    Now5 = <<"2019-12-30T11:50:12.000001Z">>,
    % Next is tuesday, jump to saturday again
    <<"2020-01-04T11:50:10.000001Z">> = next_fire_time(Now5, P2, #{}),

    % Lets set for 3 step days
    P3 = P1#{daily_step_days => 3},

    % Day 23, no previous date, fire is 24 at 11:50:10
    <<"2019-12-24T11:50:10.000001Z">> = Last1 = next_fire_time(Now2, P3, #{}),

    % Fire was 24 at 11:50:10, now is 11:50:12, should be 25, but step 3 days -> 27 11:50:10
    Now6 = <<"2019-12-24T11:50:12.000001Z">>,
    <<"2019-12-27T11:50:10.000001Z">> = next_fire_time(Now6, P3, #{last_fire_time=>Last1}),

    % It would be due for 26 -> 27 again
    Now7 = <<"2019-12-25T11:50:12.000001Z">>,
    <<"2019-12-27T11:50:10.000001Z">> = next_fire_time(Now7, P3, #{last_fire_time=>Last1}),

    % It would be due for 26 -> 27 again
    Now8 = <<"2019-12-26T11:50:09.000001Z">>,
    <<"2019-12-27T11:50:10.000001Z">> = next_fire_time(Now8, P3, #{last_fire_time=>Last1}),

    % It would be due for 27 -> 27 again
    Now9 = <<"2019-12-26T11:50:12.000001Z">>,
    <<"2019-12-27T11:50:10.000001Z">> = Last2 = next_fire_time(Now9, P3, #{last_fire_time=>Last1}),

    % It would be due for 28, jumps to 30
    Now10 = <<"2019-12-27T11:50:12.000001Z">>,
    <<"2019-12-30T11:50:10.000001Z">> = next_fire_time(Now10, P3, #{last_fire_time=>Last2}),
    ok.


daily2_test() ->
    {ok, Now1} = nklib_date:to_epoch("2019-12-23T00:00:00Z", secs),
    P0 = #{
        repeat => daily,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10
    },
    P1 = P0#{daily_step_days => 3},
    [
        <<"2019-12-23T11:50:10.000001Z">>,
        <<"2019-12-26T11:50:10.000001Z">>,
        <<"2019-12-29T11:50:10.000001Z">>,
        <<"2020-01-01T11:50:10.000001Z">>,
        <<"2020-01-04T11:50:10.000001Z">>,
        <<"2020-01-07T11:50:10.000001Z">>,
        <<"2020-01-10T11:50:10.000001Z">>,
        <<"2020-01-13T11:50:10.000001Z">>,
        <<"2020-01-16T11:50:10.000001Z">>,
        <<"2020-01-19T11:50:10.000001Z">>
    ] = get_dates(Now1, 10, P1),

    P2 = P0#{
        daily_week_days => [1,2,3,4,5],
        start_date => <<"2019-12-23T11:51:00Z">>,
        stop_date => <<"2020-01-02T00:00:00Z">>
    },
    [
        <<"2019-12-23T11:50:10.000001Z">>, % Monday
        <<"2019-12-24T11:50:10.000001Z">>,
        <<"2019-12-25T11:50:10.000001Z">>,
        <<"2019-12-26T11:50:10.000001Z">>,
        <<"2019-12-27T11:50:10.000001Z">>, % Friday
        <<"2019-12-30T11:50:10.000001Z">>, % Monday
        <<"2019-12-31T11:50:10.000001Z">>,
        <<"2020-01-01T11:50:10.000001Z">>
    ] = get_dates(Now1, 10, P2),

    % On March 31, Summer time starts
    {ok, Now2} = nklib_date:to_epoch("2019-03-30T00:00:00Z", secs),
    [
        <<"2019-03-30T11:50:10.000001Z">>,
        <<"2019-03-31T10:50:10.000001Z">>,  % 1h less
        <<"2019-04-01T10:50:10.000001Z">>,
        <<"2019-04-02T10:50:10.000001Z">>,
        <<"2019-04-03T10:50:10.000001Z">>
    ] = get_dates(Now2, 5, P0),
    ok.


weekly1_test() ->
    %%
    {ok, Now1} = nklib_date:to_epoch("2019-12-23T11:50:09Z", secs),
    P1 = #{
        repeat => weekly,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10,
        weekly_day => 1
    },
    % Still fire today
    <<"2019-12-23T11:50:10.000001Z">> = next_fire_time(Now1, P1, #{}),

    % Two seconds later, is already for tomorrow, but we said on mondays
    {ok, Now2} = nklib_date:to_epoch("2019-12-23T11:50:11Z", secs),
    <<"2019-12-30T11:50:10.000001Z">> = next_fire_time(Now2, P1, #{}),
    ok.


weekly2_test() ->
    {ok, Now1} = nklib_date:to_epoch("2019-03-01T00:00:00Z", secs), % Thursday
    P1 = #{
        repeat => weekly,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10,
        weekly_day => 3 % On Wednesdays
    },
    [
        <<"2019-03-06T11:50:10.000001Z">>,  % Next Wed
        <<"2019-03-13T11:50:10.000001Z">>,
        <<"2019-03-20T11:50:10.000001Z">>,
        <<"2019-03-27T11:50:10.000001Z">>,
        <<"2019-04-03T10:50:10.000001Z">>,  % Summer time
        <<"2019-04-10T10:50:10.000001Z">>,
        <<"2019-04-17T10:50:10.000001Z">>,
        <<"2019-04-24T10:50:10.000001Z">>,
        <<"2019-05-01T10:50:10.000001Z">>,
        <<"2019-05-08T10:50:10.000001Z">>
    ] = get_dates(Now1, 10, P1),

    P2 = P1#{weekly_day => 0},  % Sundays
    {ok, Now2} = nklib_date:to_epoch("2019-12-29T00:00:00Z", secs), % Sunday
    [
        <<"2019-12-29T11:50:10.000001Z">>,
        <<"2020-01-05T11:50:10.000001Z">>
    ] = get_dates(Now2, 2, P2),

    {ok, Now3} = nklib_date:to_epoch("2019-12-30T00:00:00Z", secs), % Monday
    [
        <<"2020-01-05T11:50:10.000001Z">>,
        <<"2020-01-12T11:50:10.000001Z">>
    ] = get_dates(Now3, 2, P2),

    P4 = P1#{weekly_day => 1},  % Mondays
    {ok, Now4} = nklib_date:to_epoch("2019-12-01T00:00:00Z", secs), % Sunday
    [
        <<"2019-12-02T11:50:10.000001Z">>,
        <<"2019-12-09T11:50:10.000001Z">>
    ] = get_dates(Now4, 2, P4),

    P5 = P1#{weekly_day => 6},  % Saturday
    {ok, Now5} = nklib_date:to_epoch("2019-12-08T00:00:00Z", secs), % Sunday
    [
        <<"2019-12-14T11:50:10.000001Z">>,
        <<"2019-12-21T11:50:10.000001Z">>
    ] = get_dates(Now5, 2, P5),
    ok.


monthly1_test() ->
    %%
    P1 = #{
        repeat => monthly,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10,
        monthly_day => 23
    },
    % Still fire today
    {ok, Now1} = nklib_date:to_epoch("2019-12-23T11:50:09Z", secs),
    <<"2019-12-23T11:50:10.000001Z">> = next_fire_time(Now1, P1, #{}),

    % Two seconds later, is already for tomorrow, but we said on 23th
    {ok, Now2} = nklib_date:to_epoch("2019-12-23T11:50:11Z", secs),
    <<"2020-01-23T11:50:10.000001Z">> = next_fire_time(Now2, P1, #{}),

    {ok, Now3} = nklib_date:to_epoch("2020-01-01T00:00:00Z", secs),
    <<"2020-01-23T11:50:10.000001Z">> = next_fire_time(Now3, P1, #{}),

    {ok, Now4} = nklib_date:to_epoch("2020-01-24T00:00:00Z", secs),
    <<"2020-02-23T11:50:10.000001Z">> = next_fire_time(Now4, P1, #{}),
    ok.


monthly2_test() ->
    P1 = #{
        repeat => monthly,
        timezone => "Europe/Madrid",
        hour => 12,
        minute => 50,
        second => 10,
        monthly_day => 2
    },
    {ok, Now1} = nklib_date:to_epoch("2019-05-01T00:00:00Z", secs),
    [
        <<"2019-05-02T10:50:10.000001Z">>,
        <<"2019-06-02T10:50:10.000001Z">>,
        <<"2019-07-02T10:50:10.000001Z">>,
        <<"2019-08-02T10:50:10.000001Z">>,
        <<"2019-09-02T10:50:10.000001Z">>,
        <<"2019-10-02T10:50:10.000001Z">>,
        <<"2019-11-02T11:50:10.000001Z">>,
        <<"2019-12-02T11:50:10.000001Z">>,
        <<"2020-01-02T11:50:10.000001Z">>,
        <<"2020-02-02T11:50:10.000001Z">>
    ] = get_dates(Now1, 10, P1),

    P2 = P1#{monthly_day => 28},
    [
        <<"2019-05-28T10:50:10.000001Z">>,
        <<"2019-06-28T10:50:10.000001Z">>,
        <<"2019-07-28T10:50:10.000001Z">>,
        <<"2019-08-28T10:50:10.000001Z">>,
        <<"2019-09-28T10:50:10.000001Z">>,
        <<"2019-10-28T11:50:10.000001Z">>,
        <<"2019-11-28T11:50:10.000001Z">>,
        <<"2019-12-28T11:50:10.000001Z">>,
        <<"2020-01-28T11:50:10.000001Z">>,
        <<"2020-02-28T11:50:10.000001Z">>
    ] = get_dates(Now1, 10, P2),

    P3 = P1#{monthly_day => last},
    [
        <<"2019-05-31T10:50:10.000001Z">>,
        <<"2019-06-30T10:50:10.000001Z">>,
        <<"2019-07-31T10:50:10.000001Z">>,
        <<"2019-08-31T10:50:10.000001Z">>,
        <<"2019-09-30T10:50:10.000001Z">>,
        <<"2019-10-31T11:50:10.000001Z">>,
        <<"2019-11-30T11:50:10.000001Z">>,
        <<"2019-12-31T11:50:10.000001Z">>,
        <<"2020-01-31T11:50:10.000001Z">>,
        <<"2020-02-29T11:50:10.000001Z">>,
        <<"2020-03-31T10:50:10.000001Z">>,
        <<"2020-04-30T10:50:10.000001Z">>
    ] = get_dates(Now1, 12, P3),
    ok.

%% ===================================================================
%% EUnit tests
%% ===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

all_test() ->
    all_tests().

-endif.
