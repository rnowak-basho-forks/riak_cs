%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

%% @doc Module to manage storage of objects and files

-module(riak_moss_put_fsm).

-behaviour(gen_fsm).

-include("riak_moss.hrl").

%% API
-export([start_link/0,
         augment_data/2,
         block_written/2,
         finalize/1]).

%% gen_fsm callbacks
-export([init/1,
         prepare/2,
         not_full/2,
         full/2,
         all_received/2,
         not_full/3,
         all_received/3,
         done/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {timeout :: pos_integer(),
                reply_pid :: pid(),
                timer_ref :: term(),
                bucket :: binary(),
                key :: binary(),
                manifest :: lfs_manifest(),
                content_length :: pos_integer(),
                content_type :: binary(),
                num_bytes_received :: non_neg_integer(),
                max_buffer_size :: non_neg_integer(),
                current_buffer_size :: non_neg_integer(),
                buffer_queue=queue:new(),
                remainder_data :: binary(),
                free_writers :: ordsets:new(),
                unacked_writes=ordsets:new()}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [], []).

augment_data(Pid, Data) ->
    gen_fsm:sync_send_event(Pid, {augment_data, Data}).

finalize(Pid) ->
    gen_fsm:sync_send_event(Pid, finalize).

block_written(Pid, BlockID) ->
    gen_fsm:sync_send_event(Pid, {block_written, BlockID, self()}).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------

%% TODO:
%% Metadata support is a future feature,
%% but I'm just stubbing it in here
%% so that I can be thinking about how it
%% might be implemented. Does it actually
%% make things more confusing?
init([Bucket, Key, ContentLength, ContentType, _Metadata, Timeout]) ->
    {ok, prepare, #state{bucket=Bucket,
                         key=Key,
                         content_length=ContentLength,
                         content_type=ContentType,
                         timeout=Timeout},
                     0}.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
prepare(timeout, State) ->
    %% do set up work

    %% 1. start the manifest_fsm proc
    %% 2. create a new manifest
    %% 3. start (or pull from poolboy)
    %%    blocks gen_servers
    %% 4. start a timer that will
    %%    send events to let us know to
    %%    to save the manifest to the
    %%    manifest_fsm

    %% TODO:
    %% this time probably
    %% shouldn't be hardcoded,
    %% and if it is, what should
    %% it be?
    {ok, TRef} = timer:send_interval(60000, self(), save_manifest),
    {next_state, not_full, State#state{timer_ref=TRef}}.

%% when a block is written
%% and we were already not full,
%% we're still not full
not_full({block_written, _BlockID, _WriterPid}, State) ->
    %% 1. Remove this block from the
    %%    unacked_writes set
    %% 2. Add this writer back to the
    %%    free_writers set
    %% 3. Maybe write another block
    {next_state, not_full, State}.

full({block_written, _BlockID, _WriterPid}, State) ->
    %% 1. Remove this block from the
    %%    unacked_writes set
    %% 2. Add this writer back to the
    %%    free_writers set
    %% 3. Maybe write another block
    %% 4. Reply to the waiting proc
    %%    that their block has been
    %%    written
    {next_state, not_full, State}.

all_received({block_written, BlockID, _WriterPid},
                    State=#state{unacked_writes=UnackedWrites}) ->
    %% 1. Remove this block from the
    %%    unacked_writes set
    %% 2. Add this writer back to the
    %%    free_writers set
    %% 3. Maybe write another block
    NewUnackedSet = ordsets:del_element(BlockID, UnackedWrites),
    case ordsets:size(NewUnackedSet) of
        0 ->
            {next_state, done, State};
        _ ->
            {next_state, all_received, State}
    end.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------

%% when this new data
%% is the last chunk
not_full({augment_data, NewData}, _From, 
                State=#state{content_length=CLength,
                             num_bytes_received=NumBytesReceived,
                             current_buffer_size=CurrentBufferSize,
                             max_buffer_size=MaxBufferSize}) ->

    case handle_chunk(CLength, NumBytesReceived, size(NewData),
                             CurrentBufferSize, MaxBufferSize) of
        last_chunk ->
            %% handle_receiving_last_chunk(),
            Reply = ok,
            {reply, Reply, all_received, State};
        accept ->
            %% handle_accept_chunk(),
            Reply = ok,
            {reply, Reply, not_full, State};
        backpressure ->
            %% stash the From pid into
            %% state
            %% handle_backpressure_for_chunk(),
            Reply = ok,
            {reply, Reply, not_full, State}
    %% 1. Maybe write another block
    end.

all_received(finalize, _From, State) ->
    %% 1. stash the From pid into our
    %%    state so that we know to reply
    %%    later with the finished manifest
    Reply = ok,
    {reply, Reply, all_received, State}.

done(finalize, _From, State) ->
    %% 1. reply immediately
    %%    with the finished manifest
    Reply = ok,
    {reply, Reply, stop, State}.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
handle_info(save_manifest, StateName, State) ->
    %% 1. save the manifest

    %% TODO:
    %% are there any times where
    %% we should be cancelling the
    %% timer here, depending on the
    %% state we're in?
    {next_state, StateName, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_chunk(_ContentLength, _NumBytesReceived, _NewDataSize, _CurrentBufferSize, _MaxBufferSize) ->
    ok.

%% @private
%% @doc Break up a data binary into a list of block-sized chunks
-spec data_blocks(binary(), pos_integer(), non_neg_integer(), [binary()]) ->
                         {[binary()], undefined | binary()}.
data_blocks(Data, ContentLength, BytesReceived, Blocks) ->
    data_blocks(Data,
                ContentLength,
                BytesReceived,
                riak_moss_lfs_utils:block_size(),
                Blocks).

%% @private
%% @doc Break up a data binary into a list of block-sized chunks
-spec data_blocks(binary(),
                  pos_integer(),
                  non_neg_integer(),
                  pos_integer(),
                  [binary()]) ->
                         {[binary()], undefined | binary()}.
data_blocks(<<>>, _, _, _, Blocks) ->
    {Blocks, undefined};
data_blocks(Data, ContentLength, BytesReceived, BlockSize, Blocks) ->
    if
        byte_size(Data) >= BlockSize ->
            <<BlockData:BlockSize/binary, RestData/binary>> = Data,
            data_blocks(RestData,
                        ContentLength,
                        BytesReceived,
                        BlockSize,
                        append_data_block(BlockData, Blocks));
        ContentLength == BytesReceived ->
            data_blocks(<<>>,
                        ContentLength,
                        BytesReceived,
                        BlockSize,
                        append_data_block(Data, Blocks));
        true ->
            {Blocks, Data}
    end.

%% @private
%% @doc Append a data block to an list of data blocks.
-spec append_data_block(binary(), [binary()]) -> [binary()].
append_data_block(BlockData, Blocks) ->
    lists:reverse([BlockData | lists:reverse(Blocks)]).
