% Internal SCCP link database keeping

% (C) 2011 by Harald Welte <laforge@gnumonks.org>
%
% All Rights Reserved
%
% This program is free software; you can redistribute it and/or modify
% it under the terms of the GNU Affero General Public License as
% published by the Free Software Foundation; either version 3 of the
% License, or (at your option) any later version.
%
% This program is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
%
% You should have received a copy of the GNU Affero General Public License
% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(sccp_links).
-behaviour(gen_server).

-include_lib("osmo_ss7/include/mtp3.hrl").

% gen_fsm callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

% our published API
-export([start_link/0]).

% client functions, may internally talk to our sccp_user server
-export([register_linkset/3, unregister_linkset/1]).
-export([register_link/3, unregister_link/2, set_link_state/3]).
-export([bind_service/2, unbind_service/1]).

-export([get_pid_for_link/2, get_pid_for_dpc_sls/2, mtp3_tx/1,
	 get_linkset_for_dpc/1, dump_all_links/0]).

-record(slink, {
	key,		% {linkset_name, sls}
	name,
	linkset_name,
	sls,
	user_pid,
	state
}).

-record(slinkset, {
	name,
	local_pc,
	remote_pc,
	user_pid,
	state,
	links
}).

-record(service, {
	name,
	service_nr,
	user_pid
}).

-record(su_state, {
	linkset_tbl,
	link_tbl,
	service_tbl
}).


% initialization code

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], [{debug, [trace]}]).

init(_Arg) ->
	LinksetTbl = ets:new(sccp_linksets, [ordered_set, named_table,
					     {keypos, #slinkset.name}]),
	ServiceTbl = ets:new(mtp3_services, [ordered_set, named_table,
				{keypos, #service.service_nr}]),

	% create a named table so we can query without reference directly
	% within client/caller process
	LinkTbl = ets:new(sccp_link_table, [ordered_set, named_table,
					    {keypos, #slink.key}]),
	{ok, #su_state{linkset_tbl = LinksetTbl, link_tbl = LinkTbl,
			service_tbl = ServiceTbl}}.

% client side API

% all write operations go through gen_server:call(), as only the ?MODULE
% process has permission to modify the table content

register_linkset(LocalPc, RemotePc, Name) ->
	gen_server:call(?MODULE, {register_linkset, {LocalPc, RemotePc, Name}}).

unregister_linkset(Name) ->
	gen_server:call(?MODULE, {unregister_linkset, {Name}}).

register_link(LinksetName, Sls, Name) ->
	gen_server:call(?MODULE, {register_link, {LinksetName, Sls, Name}}).

unregister_link(LinksetName, Sls) ->
	gen_server:call(?MODULE, {unregister_link, {LinksetName, Sls}}).

set_link_state(LinksetName, Sls, State) ->
	gen_server:call(?MODULE, {set_link_state, {LinksetName, Sls, State}}).

% bind a service (such as ISUP, SCCP) to the MTP3 link manager
bind_service(ServiceNum, ServiceName) ->
	gen_server:call(?MODULE, {bind_service, {ServiceNum, ServiceName}}).

% unbind a service (such as ISUP, SCCP) from the MTP3 link manager
unbind_service(ServiceNum) ->
	gen_server:call(?MODULE, {unbind_service, {ServiceNum}}).

% the lookup functions can directly use the ets named_table from within
% the client process, no need to go through a synchronous IPC

get_pid_for_link(LinksetName, Sls) ->
	case ets:lookup(sccp_link_table, {LinksetName, Sls}) of
	    [#slink{user_pid = Pid}] ->	
		% FIXME: check the link state 
		{ok, Pid};
	    _ ->
		{error, no_such_link}
	end.

% Resolve linkset name directly connected to given point code
get_linkset_for_dpc(Dpc) ->
	Ret = ets:match_object(sccp_linksets,
			       #slinkset{remote_pc = Dpc, _ = '_'}),
	case Ret of
	    [] ->
		{error, undefined};
	    [#slinkset{name=Name}|_Tail] ->
		{ok, Name}
	end.

% resolve link-handler Pid for given (directly connected) point code/sls
get_pid_for_dpc_sls(Dpc, Sls) ->
	case get_linkset_for_dpc(Dpc) of
	    {error, Err} ->
		{error, Err};
	    {ok, LinksetName} ->
		get_pid_for_link(LinksetName, Sls)
	end.

% process a received message on an underlying link
mtp3_rx(Mtp3 = #mtp3_msg{service_ind = Serv}) ->
	case ets:lookup(mtp3_services, Serv) of
	     [#service{user_pid = Pid}] ->
		gen_server:cast(Pid,
				osmo_util:make_prim('MTP', 'TRANSFER',
						    indication, Mtp3));
	    _ ->
		% FIXME: send back some error message on MTP level
		ok
	end.


% transmit a MTP3 message via any of the avaliable links for the DPC
mtp3_tx(Mtp3 = #mtp3_msg{routing_label = RoutLbl}) ->
	#mtp3_routing_label{dest_pc = Dpc, sig_link_sel = Sls} = RoutLbl,
	% discover the link through which we shall send
	case get_pid_for_dpc_sls(Dpc, Sls) of
	    {error, Error} ->
		{error, Error};
	    {ok, Pid} ->
		    gen_server:cast(Pid,
				osmo_util:make_prim('MTP', 'TRANSFER',
						    request, Mtp3))
	end.

dump_all_links() ->
	List = ets:tab2list(sccp_linksets),
	dump_linksets(List).

dump_linksets([]) ->
	ok;
dump_linksets([Head|Tail]) when is_record(Head, slinkset) ->
	dump_single_linkset(Head),
	dump_linksets(Tail).

dump_single_linkset(Sls) when is_record(Sls, slinkset) ->
	#slinkset{name = Name, local_pc = Lpc, remote_pc = Rpc,
		  state = State} = Sls,
	io:format("Linkset ~p, Local PC: ~p, Remote PC: ~p, State: ~p~n",
		  [Name, Lpc, Rpc, State]),
	dump_linkset_links(Name).

dump_linkset_links(Name) ->
	List = ets:match_object(sccp_link_table,
				#slink{key={Name,'_'}, _='_'}),
	dump_links(List).

dump_links([]) ->
	ok;
dump_links([Head|Tail]) when is_record(Head, slink) ->
	#slink{name = Name, sls = Sls, state = State} = Head,
	io:format("  Link ~p, SLS: ~p, State: ~p~n",
		  [Name, Sls, State]),
	dump_links(Tail).


% server side code

handle_call({register_linkset, {LocalPc, RemotePc, Name}},
				{FromPid, _FromRef}, S) ->
	#su_state{linkset_tbl = Tbl} = S,
	Ls = #slinkset{local_pc = LocalPc, remote_pc = RemotePc,
		       name = Name, user_pid = FromPid},
	case ets:insert_new(Tbl, Ls) of
	    false ->
		{reply, {error, ets_insert}, S};
	    _ ->
		% We need to trap the user Pid for EXIT
		% in order to automatically remove any links/linksets if
		% the user process dies
		link(FromPid),
		{reply, ok, S}
	end;

handle_call({unregister_linkset, {Name}}, {FromPid, _FromRef}, S) ->
	#su_state{linkset_tbl = Tbl} = S,
	ets:delete(Tbl, Name),
	{reply, ok, S};

handle_call({register_link, {LsName, Sls, Name}},
				{FromPid, _FromRef}, S) ->
	#su_state{linkset_tbl = LinksetTbl, link_tbl = LinkTbl} = S,
	% check if linkset actually exists
	case ets:lookup(LinksetTbl, LsName) of
	    [#slinkset{}] ->
		Link = #slink{name = Name, sls = Sls, state = down,
			      user_pid = FromPid, key = {LsName, Sls}},
		case ets:insert_new(LinkTbl, Link) of
		    false ->
			{reply, {error, link_exists}, S};
		    _ ->
			% We need to trap the user Pid for EXIT
			% in order to automatically remove any links if
			% the user process dies
			link(FromPid),
			{reply, ok, S}
		end;
	    _ ->
		{reply, {error, no_such_linkset}, S}
	end;

handle_call({unregister_link, {LsName, Sls}}, {FromPid, _FromRef}, S) ->
	#su_state{link_tbl = LinkTbl} = S,
	ets:delete(LinkTbl, {LsName, Sls}),
	{reply, ok, S};

handle_call({set_link_state, {LsName, Sls, State}}, {FromPid, _}, S) ->
	#su_state{link_tbl = LinkTbl} = S,
	case ets:lookup(LinkTbl, {LsName, Sls}) of
	    [] ->
		{reply, {error, no_such_link}, S};
	    [Link] ->
		NewLink = Link#slink{state = State},
		ets:insert(LinkTbl, NewLink),
		{reply, ok, S}
	end;

handle_call({bind_service, {SNum, SName}}, {FromPid, _},
	    #su_state{service_tbl = ServTbl} = S) ->
	NewServ = #service{name = SName, service_nr = SNum,
			   user_pid = FromPid},
	case ets:insert_new(ServTbl, NewServ) of
	    false ->
		{reply, {error, ets_insert}, S};
	    _ ->
		{reply, ok, S}
	end;
handle_call({unbind_service, {SNum}}, {FromPid, _},
	    #su_state{service_tbl = ServTbl} = S) ->
	ets:delete(ServTbl, SNum),
	{reply, ok, S}.

handle_cast(Info, S) ->
	error_logger:error_report(["unknown handle_cast",
				  {module, ?MODULE},
				  {info, Info}, {state, S}]),
	{noreply, S}.

handle_info({'EXIT', Pid, Reason}, S) ->
	io:format("EXIT from Process ~p (~p), cleaning up tables~n",
		  [Pid, Reason]),
	#su_state{linkset_tbl = LinksetTbl, link_tbl = LinkTbl} = S,
	ets:match_delete(LinksetTbl, #slinkset{user_pid = Pid}),
	ets:match_delete(LinkTbl, #slink{user_pid = Pid}),
	{noreply, S};
handle_info(Info, S) ->
	error_logger:error_report(["unknown handle_info",
				  {module, ?MODULE},
				  {info, Info}, {state, S}]),
	{noreply, S}.

terminate(Reason, _S) ->
	io:format("terminating ~p with reason ~p", [?MODULE, Reason]),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
