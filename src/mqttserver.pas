unit mqttserver;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ExtCtrls, Buffers, Logging, PasswordMan,
  MQTTConsts, MQTTPackets, MQTTPacketDefs, MQTTSubscriptions,
  MQTTMessages;

// TODO: Send Willmessage on disconnect
type
  TMQTTServer               = class;
  TMQTTServerConnection     = class;
  TMQTTServerConnectionList = class;
  TMQTTSessionList          = class;
  TMQTTSession              = class;

  TMQTTConnectionNotifyEvent = procedure (AConnection: TMQTTServerConnection) of object;
  TMQTTValidateSubscriptionEvent = procedure (AConnection: TMQTTServerConnection; ASubscription: TMQTTSubscription; var QOS: TMQTTQOSType; var Allow: Boolean) of object;
  TMQTTValidateClientIDEvent = procedure (AServer: TMQTTServer; AClientID: UTF8String; var Allow: Boolean) of object;
  TMQTTConnectionErrorEvent = procedure (AConnection: TMQTTServerConnection; ErrCode: Word; ErrMsg: String) of object;
  TMQTTConnectionSendDataEvent = procedure (AConnection: TMQTTServerConnection) of object;

  EMQTTConnectionError = class(Exception);

  { TMQTTServerConnection }

  TMQTTServerConnectionState = (ssNew,ssConnected,ssDisconnecting,ssDisconnected);

const
  SERVER_CONNECTION_STATE_NAMES: array[TMQTTServerConnectionState] of String =
    ('New','Connected','Disconnecting','Disconnected');

type
  TMQTTServerConnection = class(TLogObject)
    private
      FServer              : TMQTTServer;
      FSession             : TMQTTSession;
      FSocket              : TObject;
      FUser                : TPasswordManagerAccount;
      FState               : TMQTTServerConnectionState;
      FInsufficientData    : Byte;
      FKeepAlive           : Word;
      FKeepAliveRemaining  : Word;
      FWillMessage         : TMQTTWillMessage;
      FClientIDGenerated   : Boolean;
      FRecvBuffer          : TBuffer;
      FSendBuffer          : TBuffer;
      procedure HandleDISCONNECTPacket;
      procedure HandleCONNECTPacket(APacket: TMQTTCONNECTPacket);
      procedure HandlePINGREQPacket;
      procedure HandlePUBACKPacket(APacket: TMQTTPUBACKPacket);
      procedure HandlePUBCOMPPacket(APacket: TMQTTPUBCOMPPacket);
      procedure HandlePUBLISHPacket1(APacket: TMQTTPUBLISHPacket);
      procedure HandlePUBLISHPacket2(APacket: TMQTTPUBLISHPacket);
      procedure HandlePUBRECPacket(APacket: TMQTTPUBRECPacket);
      procedure HandlePUBRELPacket(APacket: TMQTTPUBRELPacket);
      procedure HandleSUBSCRIBEPacket(APacket: TMQTTSUBSCRIBEPacket);
      procedure HandleUNSUBSCRIBEPacket(APacket: TMQTTUNSUBSCRIBEPacket);
      procedure HandlePUBLISHPacket(APacket: TMQTTPUBLISHPacket);
      function InitNetworkConnection(APacket: TMQTTCONNECTPacket): byte;
      function InitSessionState(APacket: TMQTTCONNECTPacket): Boolean;
      function ValidateSubscription(ASubscription: TMQTTSubscription; var QOS: TMQTTQOSType): Boolean; virtual;
      procedure ValidateSubscriptions(AList: TMQTTSubscriptionList; ReturnCodes: TBuffer);
      procedure CheckTimeout;
      procedure SendWillMessage;
      procedure Accepted;
      procedure Timeout;
      procedure Disconnect;
      procedure Bail(ErrCode: Word);
    public
      constructor Create(AServer: TMQTTServer);
      destructor Destroy; override;
      // Methods
      procedure Publish(Topic: UTF8String; Data: String; QOS: TMQTTQOSType = qtAT_MOST_ONCE; Retain: Boolean = False; Duplicate: Boolean = False);
      procedure Disconnected;
      procedure DataAvailable(Buffer: TBuffer);
      // Properties
      property SendBuffer  : TBuffer read FSendBuffer;
      property RecvBuffer  : TBuffer read FRecvBuffer;
      property Socket      : TObject read FSocket write FSocket;
      property State       : TMQTTServerConnectionState read FState;
      property WillMessage : TMQTTWillMessage read FWillMessage write FWillMessage;
      property Server      : TMQTTServer read FServer;
      property Session     : TMQTTSession read FSession;
      property User        : TPasswordManagerAccount read FUser;
      property ClientIDGenerated : Boolean read FClientIDGenerated write FClientIDGenerated;
  end;

  { TMQTTServerConnectionList }

  TMQTTServerConnectionList = class(TObject)
    private
      FList: TList;
      function GetCount: Integer;
      function GetItem(Index: Integer): TMQTTServerConnection;
      procedure CheckTimeouts;
    public
      constructor Create;
      destructor Destroy; override;
      //
      procedure Clear;
      procedure Add(ASession: TMQTTServerConnection);
      procedure Remove(ASession: TMQTTServerConnection);
      procedure Delete(Index: Integer);
      //function Find(ClientID: UTF8String): TMQTTServerConnection;
      //
      property Count: Integer read GetCount;
      property Items[Index: Integer]: TMQTTServerConnection read GetItem; default;
  end;

  { TMQTTServer }

  TMQTTServer = class(TComponent)
    private
      FConnections                : TMQTTServerConnectionList;
      FSessions                   : TMQTTSessionList;
      FPasswords                  : TPasswordManager;
      FRetainedMessages           : TMQTTMessageList;
      FEnabled                    : Boolean;
      FRequireAuthentication      : Boolean;
      FAllowNullClientIDs         : Boolean;
      FStrictClientIDValidation   : Boolean;
      FMaximumQOS                 : TMQTTQOSType;
      //
      FTimer                      : TTimer;
      FTimerTicks                 : Byte;                    // Accumulator
      // Connection related events
      FOnAccepted                 : TMQTTConnectionNotifyEvent;
      FOnDisconnect               : TMQTTConnectionNotifyEvent;
      FOnDisconnected             : TMQTTConnectionNotifyEvent;
      FOnError                    : TMQTTConnectionErrorEvent;
      FOnConnectionsChanged       : TNotifyEvent;
      //
      FOnSendData                 : TMQTTConnectionSendDataEvent;
      FOnValidateSubscription     : TMQTTValidateSubscriptionEvent;
      FOnValidateClientID         : TMQTTValidateClientIDEvent;
      FOnSubscriptionsChanged     : TNotifyEvent;
      FOnSessionsChanged          : TNotifyEvent;
      FOnRetainedMessagesChanged  : TNotifyEvent;
      // Timer routines
      procedure ProcessAckQueues;
      procedure ProcessSessionAges;
      procedure HandleTimer(Sender: TObject);
    protected
      // Methods that trigger event handlers
      procedure Accepted(Connection: TMQTTServerConnection); virtual;
      procedure Disconnected(Connection: TMQTTServerConnection); virtual;
      procedure Disconnect(Connection: TMQTTServerConnection); virtual;
      procedure SendData(Connection: TMQTTServerConnection); virtual;
      procedure ConnectionsChanged; virtual;
      procedure SubscriptionsChanged; virtual;
      procedure SessionsChanged; virtual;
      procedure RetainedMessagesChanged; virtual;
      procedure Loaded; override;
      //
      procedure DispatchMessage(Sender: TMQTTSession; Topic: UTF8String; Data: String; QOS: TMQTTQOSType; Retain: Boolean);
      procedure SendPendingMessages;
      procedure SendRetainedMessages(Session: TMQTTSession); overload;
      procedure SendRetainedMessages(Session: TMQTTSession; Subscription: TMQTTSubscription); overload;
      function ValidateClientID(AClientID: UTF8String): Boolean; virtual;
    public
      Log: TLogDispatcher;
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
      function StartConnection: TMQTTServerConnection; virtual;
      property Connections: TMQTTServerConnectionList read FConnections;
      property Sessions: TMQTTSessionList read FSessions;
      property Passwords: TPasswordManager read FPasswords;
      property RetainedMessages: TMQTTMessageList read FRetainedMessages;
    published
      property Enabled: Boolean read FEnabled write FEnabled default true;
      property MaximumQOS: TMQTTQOSType read FMaximumQOS write FMaximumQOS default qtEXACTLY_ONCE;
      property RequireAuthentication: Boolean read FRequireAuthentication write FRequireAuthentication default true;
      property AllowNullClientIDs: Boolean read FAllowNullClientIDs write FAllowNullClientIds default false;
      property StrictClientIDValidation: Boolean read FStrictClientIDValidation write FStrictClientIDValidation default false;
      //
      property OnAccepted                 : TMQTTConnectionNotifyEvent read FOnAccepted write FOnAccepted;
      property OnDisconnect               : TMQTTConnectionNotifyEvent read FOnDisconnect write FOnDisconnect;
      property OnDisconnected             : TMQTTConnectionNotifyEvent read FOnDisconnected write FOnDisconnected;
      property OnSendData                 : TMQTTConnectionSendDataEvent read FOnSendData write FOnSendData;
      property OnError                    : TMQTTConnectionErrorEvent read FOnError write FOnError;
      property OnConnectionsChanged       : TNotifyEvent read FOnConnectionsChanged write FOnConnectionsChanged;
      property OnValidateSubscription     : TMQTTValidateSubscriptionEvent read FOnValidateSubscription write FOnValidateSubscription;
      property OnValidateClientID         : TMQTTValidateClientIDEvent read FOnValidateClientID write FOnValidateClientID;
      property OnSubscriptionsChanged     : TNotifyEvent read FOnSubscriptionsChanged write FOnSubscriptionsChanged;
      property OnSessionsChanged          : TNotifyEvent read FOnSessionsChanged write FOnSessionsChanged;
      property OnRetainedMessagesChanged  : TNotifyEvent read FOnRetainedMessagesChanged write FOnRetainedMessagesChanged;
  end;

  { TMQTTSession }

  TMQTTSession = class(TLogObject)
    private
      FServer              : TMQTTServer;
      FConnection          : TMQTTServerConnection;
      FSubscriptions       : TMQTTSubscriptionList;
      FPacketIDManager     : TMQTTPacketIDManager;
      FPendingTransmission : TMQTTMessageList; // QoS 1 and QoS 2 messages pending transmission to the Client.
      FWaitingForAck       : TMQTTPacketQueue; // QoS 1 and QoS 2 messages which have been sent to the Client, but have not been completely acknowledged.
      FPendingDispatch     : TMQTTPacketQueue; // QoS 2 messages which have been received from the Client, but have not been completely acknowledged.
      FClientID            : UTF8String;
      FDescription         : String;
      FMaximumQOS          : TMQTTQOSType;
      FAge                 : Integer;
      procedure SendRetainedMessages(NewSubscriptions: TMQTTSubscriptionList);
      procedure SendPendingMessages;
      procedure DispatchMessage(Msg: TMQTTMessage);
      procedure ProcessAckQueue;
      procedure ProcessSessionAges;
    public
      constructor Create(AServer: TMQTTServer; AClientID: UTF8String);
      destructor Destroy; override;
      // Methods
      procedure Clean;
      // Relations
      property Subscriptions: TMQTTSubscriptionList read FSubscriptions;
      property Server: TMQTTServer read FServer;
      property Connection: TMQTTServerConnection read FConnection write FConnection;
      // Attributes
      property ClientID: UTF8String read FClientID;
      property Description: String read FDescription write FDescription;
      property MaximumQOS: TMQTTQOSType read FMaximumQOS write FMaximumQOS;
      property Age: Integer read FAge write FAge;
  end;

  { TMQTTSessionList }

  TMQTTSessionList = class(TObject)
    private
      FServer: TMQTTServer;
      FList: TList;
      function GenerateRandomClientID: UTF8String;
      function GetCount: Integer;
      function GetItem(Index: Integer): TMQTTSession;
      function GetRandomClientIDChar: Char;
    public
      constructor Create(AServer: TMQTTServer);
      destructor Destroy; override;
      //
      procedure Clear;
      function IsStrictlyValid(ClientID: UTF8String): Boolean;
      function GetUniqueClientID: UTF8String;
      function New(ClientID: UTF8String): TMQTTSession;
      procedure Add(AItem: TMQTTSession);
      function Find(ClientID: UTF8String): TMQTTSession;
      procedure Delete(Index: Integer);
      procedure Remove(AItem: TMQTTSession);
      // Properties
      property Server: TMQTTServer read FServer;
      property Count: Integer read GetCount;
      property Items[Index: Integer]: TMQTTSession read GetItem; default;
  end;

implementation

{ TMQTTServer }

constructor TMQTTServer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Log                    := TLogDispatcher.Create(Name);
  FMaximumQOS            := qtEXACTLY_ONCE;
  FEnabled               := True;
  FAllowNullClientIDs    := False;
  FRequireAuthentication := True;
  FRetainedMessages      := TMQTTMessageList.Create;
  FPasswords             := TPasswordManager.Create;
  FConnections           := TMQTTServerConnectionList.Create;
  FSessions              := TMQTTSessionList.Create(Self);
  FTimer                 := TTimer.Create(nil);
  FTimer.OnTimer         := @HandleTimer;
end;

destructor TMQTTServer.Destroy;
begin
  FTimer.OnTimer := nil;
  FTimer.Enabled := False;
  FTimer.Free;
  FSessions.Free;
  FConnections.Free;
  FPasswords.Free;
  FRetainedMessages.Free;
  Log.Free;
  inherited Destroy;
end;

procedure TMQTTServer.ProcessSessionAges;
var
  X: Integer;
  Session: TMQTTSession;
begin
  for X := 0 to Sessions.Count - 1 do
    begin
      Session := Sessions[X];
      if Assigned(Session) then
        Session.ProcessSessionAges;
    end;
end;

procedure TMQTTServer.ProcessAckQueues;
var
  X: Integer;
  Session: TMQTTSession;
begin
  for X := 0 to Sessions.Count - 1 do
    begin
      Session := Sessions[X];
      if Assigned(Session) then
        Session.ProcessAckQueue;
    end;
end;

procedure TMQTTServer.HandleTimer(Sender: TObject);
begin
  // Runs every second
  Connections.CheckTimeouts;
  ProcessAckQueues;
  inc(FTimerTicks);
  if FTimerTicks = 60 then
    begin
      FTimerTicks := 0;
      // Runs every minute
      ProcessSessionAges;
    end;
end;

procedure TMQTTServer.Accepted(Connection: TMQTTServerConnection);
begin
  if Assigned(FOnAccepted) then
    FOnAccepted(Connection);
end;

procedure TMQTTServer.Disconnected(Connection: TMQTTServerConnection);
begin
  if Assigned(FOnDisconnected) then
    FOnDisconnected(Connection);
end;

procedure TMQTTServer.Disconnect(Connection: TMQTTServerConnection);
begin
  if Assigned(FOnDisconnect) then
    FOnDisconnect(Connection);
end;

procedure TMQTTServer.SendData(Connection: TMQTTServerConnection);
begin
  if Assigned(Connection) and Assigned(Connection.Session) then
    Connection.Session.Age := 0;
  if Assigned(FOnSendData) then
    FOnSendData(Connection);
end;

procedure TMQTTServer.ConnectionsChanged;
begin
  if Assigned(FOnConnectionsChanged) then
    FOnConnectionsChanged(Self);
end;

procedure TMQTTServer.SubscriptionsChanged;
begin
  // Called after a batch of subscriptions has been updated or removed.
  // i.e. override to update stringgrids and treeviews in a UI
  if Assigned(FOnSubscriptionsChanged) then
    FOnSubscriptionsChanged(Self);
end;

procedure TMQTTServer.SessionsChanged;
begin
  if Assigned(FOnSessionsChanged) then
    FOnSessionsChanged(Self);
end;

procedure TMQTTServer.RetainedMessagesChanged;
begin
  if Assigned(FOnRetainedMessagesChanged) then
    FOnRetainedMessagesChanged(Self);
end;

procedure TMQTTServer.Loaded;
begin
  inherited Loaded;
  Log.Name := Name;
end;

function TMQTTServer.ValidateClientID(AClientID: UTF8String): Boolean;
begin
  Result := True;
  if Assigned(FOnValidateClientID) then
    FOnValidateClientID(Self,AClientID,Result);
end;

function TMQTTServer.StartConnection: TMQTTServerConnection;
begin
  if FEnabled then
    Result := TMQTTServerConnection.Create(Self)
  else
    Result := nil;
end;

procedure TMQTTServer.DispatchMessage(Sender: TMQTTSession; Topic: UTF8String; Data: String; QOS: TMQTTQOSType; Retain: Boolean);
var
  I: Integer;
  S: TMQTTSession;
  M: TMQTTMessage;
begin
  M := TMQTTMessage.Create;
  try
    M.ClientID := Sender.ClientID;
    M.Topic := Topic;
    M.Data := Data;
    M.QOS := QOS;
    M.Retain := Retain;
    if M.Tokens.Valid then
      begin
        if M.Retain then
          begin
            RetainedMessages.Update(M);
            RetainedMessagesChanged;
            M := M.Clone;
            M.Retain := False;
          end;
        for I := 0 to Sessions.Count - 1 do
          begin
            S := Sessions[I];
            if S <> Sender then
              S.DispatchMessage(M);
          end;
      end;
  finally
    M.Free;
  end;
end;

procedure TMQTTServer.SendPendingMessages;
var
  I: Integer;
  C: TMQTTServerConnection;
  S: TMQTTSession;
begin
  for I := 0 to Connections.Count - 1 do
    begin
      C := Connections[I];
      if Assigned(C) and (C.State <> ssDisconnected) then
        begin
          S := C.Session;
          if Assigned(S) then
            S.SendPendingMessages;
        end;
    end;
end;

procedure TMQTTServer.SendRetainedMessages(Session: TMQTTSession);
var
  I: Integer;
  M: TMQTTMessage;
begin
  for I := 0 to RetainedMessages.Count - 1 do
    begin
      M := RetainedMessages[I];
      M.Retain := True;
      Session.DispatchMessage(M);
    end;
end;

procedure TMQTTServer.SendRetainedMessages(Session: TMQTTSession; Subscription: TMQTTSubscription);
var
  I: Integer;
  M: TMQTTMessage;
begin
  for I := 0 to RetainedMessages.Count - 1 do
    begin
      M := RetainedMessages[I];
      M.Retain := True;
      if Subscription.IsMatch(M.Tokens) then
        Session.FPendingTransmission.Add(M.Clone);
    end;
end;

{ TMQTTServerConnection }

constructor TMQTTServerConnection.Create(AServer: TMQTTServer);
begin
  Assert(Assigned(AServer));
  inherited Create;
  Log.Name := 'Connection';
  FServer  := AServer;
  FServer.Connections.Add(Self);
  FSendBuffer          := TBuffer.Create;
  FRecvBuffer          := TBuffer.Create;
  FKeepAlive           := MQTT_DEFAULT_KEEPALIVE;
  FKeepAliveRemaining  := FKeepAlive;
  FWillMessage         := TMQTTWillMessage.Create;
  FServer.ConnectionsChanged;
end;

destructor TMQTTServerConnection.Destroy;
begin
  FSocket := nil;
  FWillMessage.Free;
  FSendBuffer.Free;
  FRecvBuffer.Free;
  FServer.Connections.Remove(Self);
  FServer.ConnectionsChanged;
  inherited Destroy;
end;

procedure TMQTTServerConnection.Accepted;
begin
  Assert(State = ssNew);
  Log.Send(mtInfo,'New connection accepted');
  Server.Accepted(Self);
end;

procedure TMQTTServerConnection.Timeout;
begin
  if State = ssConnected then
    begin
      FState := ssDisconnecting;
      Log.Send(mtWarning,'Connection timed out');
      SendWillMessage;
      if FState = ssDisconnected then
        begin
          Server.Disconnect(Self);
          if Assigned(FSession) then
            FSession.FConnection := nil;
          Destroy;
        end;
    end;
end;

procedure TMQTTServerConnection.Disconnect;
begin
  if (State = ssConnected) then
    begin
      Log.Send(mtInfo,'Connection disconnecting');
      FState := ssDisconnecting;
      Server.Disconnect(Self);
      if Assigned(FSession) then
        if Self.FClientIDGenerated then
          begin
            FSession.Clean;
            Server.Sessions.Remove(FSession);
            FSession.Destroy;
          end
        else
          FSession.FConnection := nil;
      FState := ssDisconnected;
      Destroy;
    end;
end;

procedure TMQTTServerConnection.Disconnected;
begin
  if (State in [ssConnected,ssDisconnecting]) then
    begin
      Log.Send(mtInfo,'Connection disconnected');
      FState := ssDisconnected;
      Server.Disconnected(Self);
      if Assigned(FSession) then
        if Self.FClientIDGenerated then
          begin
            FSession.Clean;
            Server.Sessions.Remove(FSession);
            FSession.Destroy;
          end
        else
          FSession.FConnection := nil;
      Destroy;
    end;
end;

procedure TMQTTServerConnection.Bail(ErrCode: Word);
var
  Msg: String;
begin
  Assert(State <> ssDisconnected);
  FState := ssDisconnecting;
  Msg := GetMQTTErrorMessage(ErrCode);
  Log.Send(mtError,'Bail: '+Msg);
  if Assigned(Server.FOnError) then
    Server.FOnError(Self,ErrCode,Msg);
  Server.Disconnect(Self);
  if Assigned(FSession) then
    FSession.FConnection := nil;
  FState := ssDisconnected;
  Destroy;
end;

procedure TMQTTServerConnection.Publish(Topic: UTF8String; Data: String; QOS: TMQTTQOSType; Retain: Boolean; Duplicate: Boolean);
var
  Packet: TMQTTPUBLISHPacket;
begin
  Assert(State in [ssConnected,ssDisconnecting]);
  Packet := TMQTTPUBLISHPacket.Create;
  try
    Packet.QOS := QOS;
    Packet.Duplicate := Duplicate;
    Packet.Retain := Retain;
    Packet.Topic := Topic;
    Packet.Data := Data;
    if QOS in [qtAT_LEAST_ONCE, qtEXACTLY_ONCE] then
      begin
        Packet.PacketID := Session.FPacketIDManager.GenerateID;
        Session.FWaitingForAck.Add(Packet);
      end;
    Packet.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending PUBLISH (%d)',[Packet.PacketID]);
    Server.SendData(Self);
  finally
    if QOS = qtAT_MOST_ONCE then
      Packet.Free;
  end;
end;

procedure TMQTTServerConnection.DataAvailable(Buffer: TBuffer);
var
  Packet: TMQTTPacket;
  DestroyPacket: Boolean;
  ErrCode: Word;
begin
  DestroyPacket := True;
  Packet := nil;
  FKeepAliveRemaining := FKeepAlive; // Receipt of any data, even invalid data, should reset KeepAlive
  ErrCode := ReadMQTTPacketFromBuffer(Buffer,Packet,State = ssConnected);
  try
    if ErrCode = MQTT_ERROR_NONE then
      begin
        if Assigned(Session) then
          Session.Age := 0;
        FInsufficientData := 0;
        if State = ssConnected then
          begin
            case Packet.PacketType of
              ptDISCONNECT  : HandleDISCONNECTPacket;
              ptPINGREQ     : HandlePINGREQPacket;
              ptSUBSCRIBE   : HandleSUBSCRIBEPacket(Packet as TMQTTSUBSCRIBEPacket);
              ptUNSUBSCRIBE : HandleUNSUBSCRIBEPacket(Packet as TMQTTUNSUBSCRIBEPacket);
              ptPUBLISH     : HandlePUBLISHPacket(Packet as TMQTTPUBLISHPacket);
              ptPUBACK      : HandlePUBACKPacket(Packet as TMQTTPUBACKPacket);
              ptPUBREC      : HandlePUBRECPacket(Packet as TMQTTPUBRECPacket);
              ptPUBREL      : HandlePUBRELPacket(Packet as TMQTTPUBRELPacket);
              ptPUBCOMP     : HandlePUBCOMPPacket(Packet as TMQTTPUBCOMPPacket);
            else
              Bail(MQTT_ERROR_UNHANDLED_PACKETTYPE);
            end;
            if Packet.PacketType = ptPUBLISH then
              DestroyPacket := (Packet as TMQTTPUBLISHPacket).QOS = qtAT_MOST_ONCE;
          end
        else
          if State = ssDisconnecting then
            case Packet.PacketType of
              ptPUBACK      : HandlePUBACKPacket(Packet as TMQTTPUBACKPacket);
              ptPUBREC      : HandlePUBRECPacket(Packet as TMQTTPUBRECPacket);
              ptPUBCOMP     : HandlePUBCOMPPacket(Packet as TMQTTPUBCOMPPacket);
            end
          else
            if (State = ssNew) and (Packet is TMQTTCONNECTPacket) then
              HandleConnectPacket(Packet as TMQTTConnectPacket)
            else
              Bail(MQTT_ERROR_NOT_CONNECTED);
      end
    else
      if ErrCode = MQTT_ERROR_INSUFFICIENT_DATA then
        if FInsufficientData >= 2 then
          Bail(ErrCode)
        else
          inc(FInsufficientData)
      else
        Bail(ErrCode);

      // More data?
    if (ErrCode = MQTT_ERROR_NONE) and (Buffer.Size > 0) then
      DataAvailable(Buffer);
  finally
    if Assigned(Packet) and (DestroyPacket) then
      FreeAndNil(Packet);
  end;
end;

function TMQTTServerConnection.InitNetworkConnection(APacket: TMQTTCONNECTPacket): byte;
var
  X: Integer;
  C: TMQTTServerConnection;
begin
  Assert(State = ssNew);
  // See if a return code has already been set by the parser.
  Result := APacket.ReturnCode;
  if Result <> MQTT_CONNACK_SUCCESS then Exit;

  // Check to ensure the server is active
  if not Server.Enabled then
    begin
      Result := MQTT_CONNACK_SERVER_UNAVAILABLE;
      Exit;
    end;

  // If a zero length ClientID is provided, generate a unique random ClientID
  if APacket.ClientID = '' then
    if APacket.CleanSession and Server.AllowNullClientIDs then
      begin
        APacket.ClientID := Server.Sessions.GetUniqueClientID;
        FClientIDGenerated := True;
      end
    else
      begin
        Result := MQTT_CONNACK_CLIENTID_REJECTED;
        Exit;
      end
  else
    FClientIDGenerated := False;

  // See if the ClientID conforms to the strict optional requirements for a ClientID
  if Server.StrictClientIDValidation and not Server.Sessions.IsStrictlyValid(APacket.ClientID) then
    begin
      Result := MQTT_CONNACK_CLIENTID_REJECTED;
      Exit;
    end;

  // Check the ClientID Whitelists and Blaclists
  if not Server.ValidateClientID(APacket.ClientID) then
    begin
      Result := MQTT_CONNACK_CLIENTID_REJECTED;
      Exit;
    end;

  // Disconnect any other connections with a matching ClientID
  for X := Server.Connections.Count - 1 downto 0 do
    begin
      C := Server.Connections[X];
      if (C <> Self) and Assigned(C.Session) and (C.Session.ClientID = APacket.ClientID) then
        C.Disconnect;
    end;
  // Authenticate the user and assign the user variable
  if APacket.UsernameFlag then
    begin
      FUser := Server.Passwords.Find(APacket.Username);
      if (not Assigned(FUser)) or (FUser.Password <> APacket.Password) then
        begin
          Result := MQTT_CONNACK_NOT_AUTHORIZED;
          Exit;
        end;
    end
  else
    begin
      FUser := nil;
      if Server.RequireAuthentication then
        begin
          Result := MQTT_CONNACK_NOT_AUTHORIZED;
          Exit;
        end;
    end;
end;

function TMQTTServerConnection.InitSessionState(APacket: TMQTTCONNECTPacket): Boolean;
begin
  // Retrieve any existing session state
  FSession := Server.Sessions.Find(APacket.ClientID);
  if Assigned(FSession) then
    begin
      Result := not APacket.CleanSession;
      if APacket.CleanSession then
        FSession.Clean;
    end
  else
    begin
      Result := False;
      FSession := Server.Sessions.New(APacket.ClientID);
    end;

  FSession.FConnection := Self;
  FKeepAlive           := APacket.KeepAlive;
  FKeepAliveRemaining  := FKeepAlive;
  FState               := ssConnected;
  FWillMessage.Assign(APacket.WillMessage);
  Server.SessionsChanged;
end;

procedure TMQTTServerConnection.HandleDISCONNECTPacket;
begin
  Log.Send(mtInfo,'Received DISCONNECT');
  Disconnect;
end;

procedure TMQTTServerConnection.HandleCONNECTPacket(APacket: TMQTTCONNECTPacket);
var
  SessionPresent : Boolean;
  ReturnCode     : Byte;
  Reply          : TMQTTCONNACKPacket;
begin
  Assert(State = ssNew);

  ReturnCode := InitNetworkConnection(APacket);

  if ReturnCode <> MQTT_CONNACK_SUCCESS then
    SessionPresent := False
  else
    SessionPresent := InitSessionState(APacket);

  Log.Send(mtInfo,'Received CONNECT. ClientID=%s Username=%s SessionPresent=%s',[APacket.ClientID,APacket.Username,BoolToStr(SessionPresent)]);

  Reply := TMQTTCONNACKPACKET.Create;
  try
    Reply.ReturnCode := ReturnCode;
    Reply.SessionPresent := SessionPresent;
    Reply.WriteToBuffer(SendBuffer);
    Accepted;
    Log.Send(mtInfo,'Sending CONNACK.  ReturnCode=%d',[ReturnCode]);
    Server.SendData(Self);
  finally
    Reply.Free;
  end;
end;

procedure TMQTTServerConnection.HandlePINGREQPacket;
var
  Reply: TMQTTPINGRESPPacket;
begin
  Log.Send(mtInfo,'Received PINGREQ');
  Reply := TMQTTPINGRESPPacket.Create;
  try
    // KeepAlive is reset in DataAvailable() in response to all packets
    Reply.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending PINGRESP');
    Server.SendData(Self);
  finally
    Reply.Free;
  end;
end;


function TMQTTServerConnection.ValidateSubscription(ASubscription: TMQTTSubscription; var QOS: TMQTTQOSType): Boolean;
begin
  // Note: 3.8.4 says "The Server might grant a lower maximum QoS than the
  // subscriber requested".  To do this, change the value of QOS to a lower value.

  // Note: 3.9.3 there is the opportunity to send an error code in the SUBACK response.
  // To do that, return false.

  Result := ASubscription.Tokens.Valid;
  if Assigned(Server.FOnValidateSubscription) then
    Server.FOnValidateSubscription(Self,ASubscription,QOS,Result);
  if ord(QOS) > ord(Server.MaximumQOS) then
    QOS := Server.MaximumQOS;
end;

procedure TMQTTServerConnection.ValidateSubscriptions(AList: TMQTTSubscriptionList; ReturnCodes: TBuffer);
var
  I: Integer;
  S: TMQTTSubscription;
  Q: TMQTTQOSType;
  RC: Byte;
begin
  Assert(Assigned(AList) and Assigned(ReturnCodes));
  for I := 0 to AList.Count - 1 do
    begin
      S := AList[I];
      Q := S.QOS;
      if ValidateSubscription(S,Q) then
        begin
          if ord(Q) < ord(S.QOS) then
            Log.Send(mtInfo,'Downgraded QoS of subscription "%s"',[S.Filter]);
          if ord(Q) > ord(S.QOS) then
            Q := S.QOS;
          RC := ord(Q);
          S.QOS := Q;
        end
      else
        begin
          RC := $80;
          Log.Send(mtWarning,'Subscription %s was not added because it generated an error',[S.Filter]);
          AList.Delete(I);
          // S.Free; // Handled by AList.Delete(I)
        end;
      ReturnCodes.Write(@RC,1);
    end;
end;

procedure TMQTTServerConnection.CheckTimeout;
begin
  if FKeepAliveRemaining = 1 then
    Timeout
  else
    if FKeepAliveRemaining > 0 then
      dec(FKeepAliveRemaining);
end;

procedure TMQTTServerConnection.SendWillMessage;
begin
  Assert(State = ssDisconnecting);
  Publish(WillMessage.Topic,WillMessage.Message,WillMessage.QOS,WillMessage.Retain,False);
  if WillMessage.QOS = qtAT_MOST_ONCE then
    FState := ssDisconnected;
end;

procedure TMQTTServerConnection.HandleSUBSCRIBEPacket(APacket: TMQTTSUBSCRIBEPacket);
var
  Reply: TMQTTSUBACKPacket;
begin
  Log.Send(mtInfo,'Received SUBSCRIBE (%d)',[APacket.PacketID]);
  Reply := TMQTTSUBACKPacket.Create;
  try
    Reply.PacketID := APacket.PacketID;
    ValidateSubscriptions(APacket.Subscriptions,Reply.ReturnCodes);
    Session.Subscriptions.MergeList(APacket.Subscriptions);
    // Send the data
    Reply.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending SUBACK (%d)',[Reply.PacketID]);
    Server.SendData(Self);
    Server.SubscriptionsChanged;
    Session.SendRetainedMessages(APacket.Subscriptions);
  finally
    Reply.Free;
  end;
end;

procedure TMQTTServerConnection.HandleUNSUBSCRIBEPacket(APacket: TMQTTUNSUBSCRIBEPacket);
var
  Reply: TMQTTUNSUBACKPacket;
begin
  Log.Send(mtInfo,'Received UNSUBSCRIBE (%d)',[APacket.PacketID]);
  Reply := TMQTTUNSUBACKPacket.Create;
  try
    Reply.PacketID := APacket.PacketID;
    if APacket.Subscriptions.RemoveInvalidSubscriptions > 0 then
      Bail(MQTT_ERROR_INVALID_SUBSCRIPTION_ENTRIES);
    Session.Subscriptions.DeleteList(APacket.Subscriptions);
    // Send the data
    Reply.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending UNSUBACK (%d)',[Reply.PacketID]);
    Server.SendData(Self);
    Server.SubscriptionsChanged;
  finally
    Reply.Free;
  end;
end;

procedure TMQTTServerConnection.HandlePUBACKPacket(APacket: TMQTTPUBACKPacket);
begin
  Log.Send(mtInfo,'Received PUBACK (%d)',[APacket.PacketID]);
  Session.FPacketIDManager.ReleaseID(APacket.PacketID);
  Session.FWaitingForAck.Remove(ptPUBLISH,APacket.PacketID);
  if State = ssDisconnecting then
    Disconnected;
end;

procedure TMQTTServerConnection.HandlePUBRECPacket(APacket: TMQTTPUBRECPacket);
var
  Reply: TMQTTPUBRELPacket;
begin
  Log.Send(mtInfo,'Received PUBREC (%d)',[APacket.PacketID]);
  Session.FWaitingForAck.Remove(ptPublish,APacket.PacketID);

  Reply := TMQTTPUBRELPacket.Create;
  Reply.PacketID := APacket.PacketID;
  Session.FWaitingForAck.Add(Reply);
  Reply.WriteToBuffer(SendBuffer);
  Log.Send(mtInfo,'Sending PUBREL (%d)',[Reply.PacketID]);
  Server.SendData(Self);
end;

procedure TMQTTServerConnection.HandlePUBRELPacket(APacket: TMQTTPUBRELPacket);
var
  Pkt: TMQTTPUBLISHPacket;
  Reply: TMQTTPUBCOMPPacket;
begin
  Log.Send(mtInfo,'Received PUBREL (%d)',[APacket.PacketID]);
  Session.FWaitingForAck.Remove(ptPUBREC,APacket.PacketID);
  Pkt := Session.FPendingDispatch.Find(ptPUBLISH,APacket.PacketID) as TMQTTPUBLISHPacket;
  if Assigned(Pkt) then
    begin
      Server.DispatchMessage(Session,Pkt.Topic,Pkt.Data,Pkt.QOS,Pkt.Retain);
      Session.FPendingDispatch.Remove(Pkt);
      Pkt.Free;
    end;
  Reply := TMQTTPUBCOMPPacket.Create;
  try
    Reply.PacketID := APacket.PacketID;
    Reply.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending PUBCOMP (%d)',[Reply.PacketID]);
    Server.SendData(Self);
    Server.SendPendingMessages;
  finally
    Reply.Free;
  end;
end;

procedure TMQTTServerConnection.HandlePUBCOMPPacket(APacket: TMQTTPUBCOMPPacket);
begin
  Log.Send(mtInfo,'Received PUBCOMP (%d)',[APacket.PacketID]);
  Session.FPacketIDManager.ReleaseID(APacket.PacketID);
  Session.FWaitingForAck.Remove(ptPUBREL,APacket.PacketID);
  if State = ssDisconnecting then
    Disconnected;
end;

procedure TMQTTServerConnection.HandlePUBLISHPacket1(APacket: TMQTTPUBLISHPacket);
var
  Reply: TMQTTPUBACKPacket;
begin
  Reply := TMQTTPUBACKPacket.Create;
  try
    Reply.PacketID := APacket.PacketID;
    Reply.WriteToBuffer(SendBuffer);
    Log.Send(mtInfo,'Sending PUBACK (%d)',[Reply.PacketID]);
    Server.SendData(Self);
    Server.DispatchMessage(Session,APacket.Topic,APacket.Data,APacket.QOS,APacket.Retain);
    Server.SendPendingMessages;
  finally
    Reply.Free;
  end;
end;

procedure TMQTTServerConnection.HandlePUBLISHPacket2(APacket: TMQTTPUBLISHPacket);
var
  Pkt    : TMQTTPUBLISHPacket;
  Reply  : TMQTTPUBRECPacket;
begin
  // If the duplicate flag is set, ensure we don't add the packet to the pending dispatch list twice
  if APacket.Duplicate then
    Pkt := Session.FPendingDispatch.Find(ptPublish,APacket.PacketID) as TMQTTPUBLISHPacket
  else
    Pkt := nil;
  if not Assigned(Pkt) then
    begin
      Pkt := APacket;
      Session.FPendingDispatch.Add(APacket);
    end;

  Reply := TMQTTPUBRECPacket.Create;
  Reply.PacketID := Pkt.PacketID;
  Session.FWaitingForAck.Add(Reply);
  Reply.WriteToBuffer(SendBuffer);
  Log.Send(mtInfo,'Sending PUBREC (%d)',[Reply.PacketID]);
  Server.SendData(Self);
end;

procedure TMQTTServerConnection.HandlePUBLISHPacket(APacket: TMQTTPUBLISHPacket);
begin
  Log.Send(mtInfo,'Received PUBLISH (PacketID=%d,QOS=%s,Retain=%s)',[APacket.PacketID,MQTTQOSTypeNames[APacket.QOS],BoolToStr(APacket.Retain,'True','False')]);
  case APacket.QOS of
    qtAT_MOST_ONCE  : Server.DispatchMessage(Session,APacket.Topic,APacket.Data,APacket.QOS,APacket.Retain);
    qtAT_LEAST_ONCE : HandlePUBLISHPacket1(APacket);
    qtEXACTLY_ONCE  : HandlePUBLISHPacket2(APacket);
  end;
end;

{ TMQTTServerConnectionList }

constructor TMQTTServerConnectionList.Create;
begin
  inherited Create;
  FList := TList.Create;
end;

destructor TMQTTServerConnectionList.Destroy;
begin
  Clear;
  FList.Free;
  inherited Destroy;
end;

function TMQTTServerConnectionList.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TMQTTServerConnectionList.GetItem(Index: Integer): TMQTTServerConnection;
begin
  Result := TMQTTServerConnection(FList[Index]);
end;

procedure TMQTTServerConnectionList.CheckTimeouts;
var
  X: Integer;
  Connection: TMQTTServerConnection;
begin
  for X := Count - 1 downto 0 do
    begin
      Connection := Items[X];
      if Assigned(Connection) then
        Connection.CheckTimeout;
    end;
end;

procedure TMQTTServerConnectionList.Clear;
var
  I: Integer;
begin
  for I := Count - 1 downto 0 do
    Items[I].Free;
end;

procedure TMQTTServerConnectionList.Add(ASession: TMQTTServerConnection);
begin
  FList.Add(ASession);
end;

procedure TMQTTServerConnectionList.Remove(ASession: TMQTTServerConnection);
begin
  FList.Remove(ASession);
end;

procedure TMQTTServerConnectionList.Delete(Index: Integer);
begin
  FList.Delete(Index);
end;

{ TMQTTSessionList }

constructor TMQTTSessionList.Create(AServer: TMQTTServer);
begin
  inherited Create;
  FServer := AServer;
  FList := TList.Create;
end;

destructor TMQTTSessionList.Destroy;
begin
  Clear;
  FList.Free;
  inherited Destroy;
end;

function TMQTTSessionList.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TMQTTSessionList.GetItem(Index: Integer): TMQTTSession;
begin
  Result := TMQTTSession(FList[Index]);
end;

procedure TMQTTSessionList.Clear;
var
  X: Integer;
begin
  for X := Count - 1 downto 0 do
    Items[X].Destroy;
  FList.Clear;
end;

function TMQTTSessionList.GetRandomClientIDChar: Char;
var
  B: Byte;
begin
  B := Random(62) + 1;
  if B < 10 then
    Result := chr($30 + B)
  else
    if B < 36 then
      Result := chr($41 + (B - 10))
    else
      Result := chr($61 + (B - 36));
end;

function TMQTTSessionList.GenerateRandomClientID: UTF8String;
var
  X: Integer;
begin
  SetLength(Result,23);
  for X := 1 to 23 do
    Result[X] := GetRandomClientIDChar;
end;

function TMQTTSessionList.GetUniqueClientID: UTF8String;
begin
  repeat
    Result := GenerateRandomClientID;
  until Find(Result) = nil;
end;

function TMQTTSessionList.IsStrictlyValid(ClientID: UTF8String): Boolean;
var
  X,L: Integer;
  C: Char;
begin
  Result := True;
  L := Length(ClientID);
  if L < 24 then
    for X := 1 to L do
      begin
        C := ClientID[X];
        if not (C in MQTTStrictClientIDValidationChars) then
          begin
            Result := False;
            Exit;
          end;
      end
  else
    Result := False;
end;

function TMQTTSessionList.New(ClientID: UTF8String): TMQTTSession;
begin
  Result := TMQTTSession.Create(FServer,ClientID);
  FList.Add(Result);
end;

procedure TMQTTSessionList.Add(AItem: TMQTTSession);
begin
  FList.Add(AItem);
end;

function TMQTTSessionList.Find(ClientID: UTF8String): TMQTTSession;
var
  X: Integer;
begin
  for X := 0 to Count - 1 do
    begin
      Result := Items[X];
      if Result.ClientID = ClientID then Exit;
    end;
  Result := nil;
end;

procedure TMQTTSessionList.Delete(Index: Integer);
begin
  FList.Delete(Index);
end;

procedure TMQTTSessionList.Remove(AItem: TMQTTSession);
begin
  FList.Remove(AItem);
end;

{ TMQTTSession }

constructor TMQTTSession.Create(AServer: TMQTTServer; AClientID: UTF8String);
begin
  inherited Create;
  FServer              := AServer;
  FSubscriptions       := TMQTTSubscriptionList.Create;
  FPendingTransmission := TMQTTMessageList.Create;
  FPendingDispatch     := TMQTTPacketQueue.Create;
  FPacketIDManager     := TMQTTPacketIDManager.Create;
  FWaitingForAck       := TMQTTPacketQueue.Create;
  FClientID            := AClientID;
  FMaximumQOS          := qtEXACTLY_ONCE;
  Log.Name             := 'Session ('+FClientID+')';
end;

destructor TMQTTSession.Destroy;
begin
  FSubscriptions.Free;
  FPendingTransmission.Free;
  FPendingDispatch.Free;
  FPacketIDManager.Free;
  FWaitingForAck.Free;
  inherited Destroy;
end;

procedure TMQTTSession.Clean;
begin
  FSubscriptions.Clear;
  FPendingTransmission.Clear;
  FWaitingForAck.Clear;
  FPendingDispatch.Clear;
  FPacketIDManager.Reset;
  FServer.SubscriptionsChanged;
end;

procedure TMQTTSession.SendPendingMessages;
var
  I: Integer;
  M: TMQTTMessage;
begin
  for I := 0 to FPendingTransmission.Count - 1 do
    begin
      M := FPendingTransmission[I];
      Connection.Publish(M.Topic,M.Data,M.QOS,M.Retain);
    end;
  FPendingTransmission.Clear;
end;

procedure TMQTTSession.DispatchMessage(Msg: TMQTTMessage);
var
  I: Integer;
  Sub: TMQTTSubscription;
  M2: TMQTTMessage;
begin
  for I := 0 to Subscriptions.Count - 1 do
    begin
      Sub := Subscriptions[I];
      if Sub.IsMatch(Msg.Tokens) then
        begin
          Sub.Age := 0;
          if Msg.QOS = qtAT_MOST_ONCE then
            begin
              // If this is a QoS0 message, send it right away
              if Assigned(Connection) and (Connection.State <> ssDisconnected) then
                Connection.Publish(Msg.Topic,Msg.Data,Msg.QOS,Msg.Retain);
            end
          else
            begin
              // Otherwise queue it to send later
              M2 := Msg.Clone;
              M2.QOS := Sub.QOS;
              FPendingTransmission.Add(M2);
            end;
        end;
    end;

end;

procedure TMQTTSession.ProcessAckQueue;
var
  I: Integer;
  Packet: TMQTTQueuedPacket;
begin
  for I := FWaitingForAck.Count - 1 downto 0 do
    begin
      Packet := FWaitingForAck[I];
      if Packet.SecondsInQueue = MQTT_RESEND_PACKET_TIMEOUT then
        begin
          if Packet.ResendCount < MQTT_MAX_PACKET_RESEND_TRIES then
            begin
              if Packet.PacketType = ptPUBLISH then
                (Packet as TMQTTPUBLISHPacket).Duplicate := True;
              Packet.WriteToBuffer(Connection.SendBuffer);
              Log.Send(mtWarning,'Resending %s packet',[Packet.PacketTypeName]);
              Server.SendData(Connection);
              Packet.SecondsInQueue := 0;
              Packet.ResendCount := Packet.ResendCount + 1;
            end
          else
            begin
              FWaitingForAck.Delete(I);
              if Packet.PacketType in [ptSUBACK,ptUNSUBACK,ptPUBACK,ptPUBCOMP] then
                FPacketIDManager.ReleaseID(Packet.PacketID);
              Log.Send(mtWarning,'A %s packet went unacknowledged by the client',[Packet.PacketTypeName]);
              Packet.Free;
            end;
        end;
    end;
end;

procedure TMQTTSession.ProcessSessionAges;
var
  I: Integer;
  Sub: TMQTTSubscription;
begin
  // Age each subscription.  If the subscription is older than the maximum subscription age and
  // it is not marked as persistent, then destroy it.
  for I := 0 to Subscriptions.Count - 1 do
    begin
      Sub := Subscriptions[I];
      if Sub.Age < MQTT_MAX_SUBSCRIPTION_AGE then
        Sub.Age := Sub.Age + 1
      else
        if not Sub.Persistent then
          Subscriptions.Delete(I);
    end;
  inc(FAge);
  // If there are no subscriptions remaining and the session is older than the maximum session age then destroy it.
  if (Subscriptions.Count = 0) and (FAge > MQTT_MAX_SESSION_AGE) then
    begin
      Server.Sessions.Remove(Self);
      Destroy;
    end;
end;

procedure TMQTTSession.SendRetainedMessages(NewSubscriptions: TMQTTSubscriptionList);
var
  I: Integer;
  Subscription: TMQTTSubscription;
begin
  for I := 0 to NewSubscriptions.Count - 1 do
    begin
      Subscription := NewSubscriptions[I];
      if Subscription.Tokens.Valid then
        Connection.Server.SendRetainedMessages(Self,Subscription);
    end;
  SendPendingMessages;
end;

end.

