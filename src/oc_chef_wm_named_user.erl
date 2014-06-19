%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92-*-
%% ex: ts=4 sw=4 et
%% @author Seth Falcon <seth@getchef.com>
%% @author Marc Paradise <marc@getchef.com>
%% Copyright 2012-2014 Chef, Inc. All Rights Reserved.
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


-module(oc_chef_wm_named_user).

-include_lib("chef_wm/include/chef_wm.hrl").
-include_lib("oc_chef_wm.hrl").

-mixin([{chef_wm_base, [content_types_accepted/2,
                        content_types_provided/2,
                        finish_request/2,
                        malformed_request/2,
                        ping/2,
                        post_is_create/2]}]).

-mixin([{?BASE_RESOURCE, [forbidden/2,
                          is_authorized/2,
                          service_available/2]}]).

%% chef_wm behaviour callbacks
-behaviour(chef_wm).
-export([
         auth_info/2,
         init/1,
         init_resource_state/1,
         conflict_message/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3
        ]).

-export([
         allowed_methods/2,
         delete_resource/2,
         from_json/2,
         to_json/2
       ]).

init(Config) ->
    chef_wm_base:init(?MODULE, Config).

init_resource_state(_Config) ->
    {ok, #user_state{}}.

request_type() ->
  "users".

allowed_methods(Req, State) ->
    {['GET', 'PUT', 'DELETE'], Req, State}.


validate_request(Method, Req, #base_state{chef_db_context = DbContext,
                                          resource_state = UserState} = State) when Method == 'GET';
                                                                                    Method == 'DELETE' ->
    User = fetch_user_data(DbContext, Req),
    UserState1 = UserState#user_state{chef_user = User},
    {Req, State#base_state{resource_state = UserState1}};
validate_request('PUT', Req, #base_state{chef_db_context = DbContext,
                                         resource_state = UserState} = State) ->
    Body = wrq:req_body(Req),
    User = fetch_user_data(DbContext, Req),
    {ok, EJson} = chef_user:parse_binary_json(Body, update, User),
    UserState1 = UserState#user_state{chef_user = User, user_data = EJson},
    {Req, State#base_state{resource_state = UserState1}}.

fetch_user_data(DbContext, Req) ->
    UserName = chef_wm_util:object_name(user, Req),
    chef_db:fetch(#chef_user{username = UserName}, DbContext).

auth_info(Req, #base_state{resource_state = #user_state{ chef_user = not_found } } = State) ->
    UserName = chef_wm_util:object_name(user, Req),
    Message = chef_wm_util:not_found_message(user, UserName),
    Req1 = chef_wm_util:set_json_body(Req, Message),
    {{halt, 404}, Req1, State#base_state{log_msg = user_not_found}};
auth_info(Req, State) ->
    auth_info(wrq:method(Req), Req, State).

auth_info(Method, Req, #base_state{resource_state = #user_state{chef_user = User}} = State) ->
    #chef_user{authz_id = AuthzId} = User,
    {auth_type(Method, AuthzId, State), Req, State}.

auth_type('PUT', AuthzId, #user_state{user_data = UserData}) ->
    ExtId = ej:get({<<"external_authentication_uid">>}, UserData),
    Recovery = ej:get({<<"recovery_authentication_enabled">>}, UserData),
    case {ExtId, Recovery} of
        {undefined, undefined} ->
            {actor, AuthzId};
        _ ->
            superuser_only
    end;
auth_type(_, AuthzId, _State) ->
    {actor, AuthzId}.

from_json(Req, #base_state{resource_state = #user_state{
                           chef_user = User,
                           user_data = UserData}} = State) ->
    case chef_wm_util:maybe_generate_key_pair(UserData) of
        keygen_timeout ->
            {{halt, 503}, Req, State#base_state{log_msg = keygen_timeout}};
        UserDataWithKeys ->
            %% Custom json body needed to maintain compatibility with opscode-account behavior.
            %% chef_wm_base:update_from_json will reply with the complete object, but
            %% clients currently expect only a URI, and a private key if the key is new.
            %%
            %% However, we will retain the returned Request since Location header wil have been
            %% correctly set if the username changed.
            case chef_wm_base:update_from_json(Req, State, User, UserDataWithKeys) of
                {true, Req1, State1} ->
                    {true, make_update_response(Req1, UserDataWithKeys), State1};
                Other ->
                    Other
            end
    end.

to_json(Req, #base_state{resource_state = #user_state{chef_user = User},
                         organization_name = OrgName} = State) ->
    EJson = chef_user:assemble_user_ejson(User, OrgName),
    Json = chef_json:encode(EJson),
    {Json, Req, State}.

delete_resource(Req, #base_state{chef_db_context = DbContext,
                                 requestor_id = RequestorId,
                                 resource_state = #user_state{ chef_user = User},
                                 organization_name = OrgName } = State) ->
    ok = oc_chef_wm_base:delete_object(DbContext, User, RequestorId),
    EJson = chef_user:assemble_user_ejson(User, OrgName),
    Req1 = chef_wm_util:set_json_body(Req, EJson),
    {true, Req1, State}.

error_message(Msg) when is_list(Msg) ->
    error_message(iolist_to_binary(Msg));
error_message(Msg) when is_binary(Msg) ->
    {[{<<"error">>, [Msg]}]}.

malformed_request_message(#ej_invalid{type = json_type, key = Key}, _Req, _State) ->
    case Key of
        undefined -> error_message([<<"Incorrect JSON type for request body">>]);
        _ ->error_message([<<"Incorrect JSON type for ">>, Key])
    end;
malformed_request_message(#ej_invalid{type = missing, key = Key}, _Req, _State) ->
    error_message([<<"Required value for ">>, Key, <<" is missing">>]);
malformed_request_message({invalid_key, Key}, _Req, _State) ->
    error_message([<<"Invalid key ">>, Key, <<" in request body">>]);
malformed_request_message(invalid_json_body, _Req, _State) ->
    error_message([<<"Incorrect JSON type for request body">>]);
malformed_request_message(#ej_invalid{type = exact, key = Key, msg = Expected},
                          _Req, _State) ->
    error_message([Key, <<" must equal ">>, Expected]);
malformed_request_message(#ej_invalid{type = string_match, msg = Error},
                          _Req, _State) ->
    error_message([Error]);
malformed_request_message(#ej_invalid{type = object_key, key = Object, found = Key},
                          _Req, _State) ->
    error_message([<<"Invalid key '">>, Key, <<"' for ">>, Object]);
malformed_request_message(#ej_invalid{type = object_value, key = Object, found = Val},
                          _Req, _State) when is_binary(Val) ->
    error_message([<<"Invalid value '">>, Val, <<"' for ">>, Object]);
malformed_request_message(#ej_invalid{type = object_value, key = Object, found = Val},
                          _Req, _State) ->
    error_message([<<"Invalid value '">>, io_lib:format("~p", [Val]),
                   <<"' for ">>, Object]);
malformed_request_message(Any, _Req, _State) ->
    error({unexpected_malformed_request_message, Any}).

%% Expected update response for users is currently just
%% "uri" and (if regenerated) "privat_key" - this function will override
%% whatever has been set in chef_wm_base:update_from_ejson with these values.
make_update_response(Request, OrigEJson) ->
    NewName = chef_user:username_from_ejson(OrigEJson),
    Uri = ?BASE_ROUTES:route(user, Request, [{name, NewName}]),

    EJson1 = {[{<<"uri">>, Uri}]},

    % private_key will be set if we generated a new private_key, in which case
    % we need to supply it to the caller.
    EJson2 = case ej:get({<<"private_key">>}, OrigEJson) of
                 undefined ->
                     EJson1;
                 Key ->
                     ej:set({<<"private_key">>}, EJson1, Key)
             end,
    chef_wm_util:set_json_body(Request, EJson2).


conflict_message(Name) ->
    Msg = iolist_to_binary([<<"User '">>, Name, <<"' already exists">>]),
    {[{<<"error">>, [Msg]}]}.