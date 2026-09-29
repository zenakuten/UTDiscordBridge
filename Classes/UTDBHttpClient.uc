class UTDBHttpClient extends Info;

struct PendingEvent
{
    var string Body;
    var bool bChat;
    var int RetryCount;
};

var UTDiscordBridgeServerActor Bridge;
var HttpSock Socket;
var array<PendingEvent> Queue;
var bool bRequestActive;
var bool bResponseReady;
var int ResponseStatus;
var float RequestStartTime;

function Initialize(UTDiscordBridgeServerActor NewBridge)
{
    Bridge = NewBridge;
}

function EnqueueChat(string PlayerName, string Msg, bool bTeam)
{
    local string Body;

    Body = StartEventJson("chat") $ ","
        $ JsonField("player", PlayerName, true)
        $ JsonBoolField("team", bTeam, true)
        $ JsonField("message", Msg, false)
        $ "}";
    AddEvent(Body, true);
}

function EnqueueMapStart()
{
    local string Body;

    Body = StartEventJson("map_start") $ "}";
    AddEvent(Body, false);
}

function EnqueuePlayerEvent(string PlayerName, bool bJoined, bool bSpectator)
{
    local string Body;

    if (bJoined)
        Body = StartEventJson("player_join") $ ",";
    else
        Body = StartEventJson("player_leave") $ ",";

    Body = Body
        $ JsonField("player", PlayerName, true)
        $ JsonBoolField("spectator", bSpectator, false)
        $ "}";
    AddEvent(Body, false);
}

function EnqueueGameEnd(PlayerReplicationInfo Winner, string Reason)
{
    local string Body;

    Body = StartEventJson("game_end") $ ","
        $ JsonField("reason", Reason, Winner != None);

    if (Winner != None)
    {
        Body = Body
            $ JsonField("winner", Winner.PlayerName, true)
            $ JsonIntField("score", int(Winner.Score), false);
    }

    Body = Body $ "}";
    AddEvent(Body, false);
}

function string StartEventJson(string EventType)
{
    return "{"
        $ JsonIntField("version", 1, true)
        $ JsonField("type", EventType, true)
        $ JsonField("webhook_url", Bridge.WebhookURL, true)
        $ JsonField("server", GetServerName(), true)
        $ JsonField("map", GetCurrentMapName(), true)
        $ JsonField("game_type", string(Level.Game.Class), false);
}

function string GetServerName()
{
    if (Bridge != None && Bridge.ServerLabel != "")
        return Bridge.ServerLabel;

    return "UT2004 Server";
}

function string GetCurrentMapName()
{
    return string(Level.Outer.Name);
}

function AddEvent(string Body, bool bChat)
{
    local int Index;

    if (Bridge == None)
        return;

    if (Bridge.QueueLimit < 1)
        Bridge.QueueLimit = 1;

    if (Queue.Length >= Bridge.QueueLimit && !DropOldestChat())
    {
        Log("UTDB queue full: dropped newest event");
        return;
    }

    Index = Queue.Length;
    Queue.Length = Index + 1;
    Queue[Index].Body = Body;
    Queue[Index].bChat = bChat;
    Queue[Index].RetryCount = 0;

    if (Bridge.bDebug)
        Log("UTDB queued event; depth" @ Queue.Length);

    if (!bRequestActive)
        SendNext();
}

function bool DropOldestChat()
{
    local int Index;

    for (Index = 0; Index < Queue.Length; Index++)
    {
        if (Queue[Index].bChat)
        {
            Queue.Remove(Index, 1);
            Log("UTDB queue full: dropped oldest chat event");
            return true;
        }
    }

    return false;
}

function SendNext()
{
    local array<string> PostData;

    if (bRequestActive || Queue.Length == 0 || Bridge == None)
        return;

    Socket = Spawn(class'HttpSock', self);
    if (Socket == None)
    {
        RetryCurrent("could not create HTTP socket");
        return;
    }

    Socket.OnComplete = RequestComplete;
    Socket.OnReturnCode = RequestReturnCode;
    Socket.OnError = RequestError;
    Socket.OnConnectionTimeout = RequestTimeout;
    Socket.OnConnectError = ConnectError;
    Socket.OnResolveFailed = ResolveFailed;
    Socket.fConnectTimout = FMax(1.0, Bridge.RequestTimeout);
    Socket.bFollowRedirect = false;
    Socket.AddHeader("Content-Type", "application/json");
    if (Bridge.RelayToken != "")
        Socket.AddHeader("X-UTDB-Token", Bridge.RelayToken);

    PostData.Length = 1;
    PostData[0] = Queue[0].Body;
    bRequestActive = true;
    bResponseReady = false;
    RequestStartTime = Level.TimeSeconds;

    if (Bridge.bDebug)
        Log("UTDB sending event; attempt" @ (Queue[0].RetryCount + 1));

    if (!Socket.postex(Bridge.RelayURL, PostData))
        RetryCurrent("request rejected by HTTP client");
}

// LibHTTP only calls OnComplete from TcpLink's Closed event, which OldUnreal
// 3374 never delivers. The relay's status line is all we need, so record it
// here and finish on the next tick, outside LibHTTP's call stack.
function RequestReturnCode(HttpSock Sender, int ReturnCode, string ReturnMessage, string HttpVer)
{
    if (!bRequestActive || Sender != Socket || bResponseReady)
        return;

    ResponseStatus = ReturnCode;
    bResponseReady = true;
}

event Tick(float DeltaTime)
{
    if (!bRequestActive)
        return;

    if (bResponseReady)
    {
        bResponseReady = false;
        HandleResponse(ResponseStatus);
        return;
    }

    // Last resort so one lost reply can never block the queue for a whole map.
    if (Bridge != None && Level.TimeSeconds - RequestStartTime > FMax(1.0, Bridge.RequestTimeout) + 25.0)
    {
        Log("UTDB no reply from relay; dropping event");
        bRequestActive = false;
        DestroySocket();
        if (Queue.Length > 0)
            Queue.Remove(0, 1);
        SendNext();
    }
}

// Still used on engines where Closed does fire.
function RequestComplete(HttpSock Sender)
{
    if (!bRequestActive || Sender != Socket)
        return;

    bResponseReady = false;
    HandleResponse(Sender.LastStatus);
}

function HandleResponse(int Status)
{
    bRequestActive = false;
    DestroySocket();

    if (Status >= 200 && Status < 300)
    {
        Queue.Remove(0, 1);
        if (Bridge.bDebug)
            Log("UTDB event delivered; depth" @ Queue.Length);
        SendNext();
    }
    else if (Status >= 400 && Status < 500 && Status != 408 && Status != 429)
    {
        Log("UTDB relay rejected event with status" @ Status);
        Queue.Remove(0, 1);
        SendNext();
    }
    else
    {
        RetryCurrent("temporary relay response" @ Status);
    }
}

function RequestError(HttpSock Sender, string ErrorMessage, optional string Param1, optional string Param2)
{
    if (Sender == Socket)
        RetryCurrent("HTTP client error");
}

function RequestTimeout(HttpSock Sender)
{
    if (Sender == Socket)
        RetryCurrent("relay connection timed out");
}

function ConnectError(HttpSock Sender)
{
    if (Sender == Socket)
        RetryCurrent("could not connect to relay");
}

function ResolveFailed(HttpSock Sender, string HostName)
{
    if (Sender == Socket)
        RetryCurrent("could not resolve relay");
}

function RetryCurrent(string Reason)
{
    local float Delay;
    local int Index;

    if (Queue.Length == 0)
        return;

    bRequestActive = false;
    bResponseReady = false;
    DestroySocket();
    Queue[0].RetryCount++;

    if (Queue[0].RetryCount > Bridge.MaxRetries)
    {
        Log("UTDB dropped event after retries:" @ Reason);
        Queue.Remove(0, 1);
        SendNext();
        return;
    }

    Delay = 1.0;
    for (Index = 1; Index < Queue[0].RetryCount; Index++)
        Delay = FMin(Delay * 2.0, 30.0);

    Log("UTDB retry scheduled:" @ Reason);
    SetTimer(Delay, false);
}

event Timer()
{
    SendNext();
}

function DestroySocket()
{
    if (Socket == None)
        return;

    Socket.OnComplete = None;
    Socket.OnReturnCode = None;
    Socket.OnError = None;
    Socket.OnConnectionTimeout = None;
    Socket.OnConnectError = None;
    Socket.OnResolveFailed = None;
    Socket.Abort();
    Socket.Destroy();
    Socket = None;
}

function string JsonField(string Key, string Value, bool bComma)
{
    local string Result;

    Result = JsonString(Key) $ ":" $ JsonString(Value);
    if (bComma)
        Result = Result $ ",";
    return Result;
}

function string JsonIntField(string Key, int Value, bool bComma)
{
    local string Result;

    Result = JsonString(Key) $ ":" $ string(Value);
    if (bComma)
        Result = Result $ ",";
    return Result;
}

function string JsonBoolField(string Key, bool Value, bool bComma)
{
    local string Result;

    Result = JsonString(Key) $ ":";
    if (Value)
        Result = Result $ "true";
    else
        Result = Result $ "false";

    if (bComma)
        Result = Result $ ",";
    return Result;
}

function string JsonString(string Value)
{
    local int Index;
    local int Code;
    local string Char;
    local string Result;
    local string Slash;
    local string Quote;

    Slash = Chr(92);
    Quote = Chr(34);
    Result = Quote;

    for (Index = 0; Index < Len(Value); Index++)
    {
        Char = Mid(Value, Index, 1);
        Code = Asc(Char);

        if (Char == Quote)
            Result = Result $ Slash $ Quote;
        else if (Char == Slash)
            Result = Result $ Slash $ Slash;
        else if (Code == 8)
            Result = Result $ Slash $ "b";
        else if (Code == 9)
            Result = Result $ Slash $ "t";
        else if (Code == 10)
            Result = Result $ Slash $ "n";
        else if (Code == 12)
            Result = Result $ Slash $ "f";
        else if (Code == 13)
            Result = Result $ Slash $ "r";
        else if (Code < 32)
            Result = Result $ " ";
        else
            Result = Result $ Char;
    }

    return Result $ Quote;
}

function Destroyed()
{
    DestroySocket();
    Super.Destroyed();
}

defaultproperties
{
    bAlwaysTick=True
}
