function onReceiveOSC(msg)
  local address = msg[1]
  if(address == '/vibrate') then vibrate() end
end

----------------------------------------------------------------------
-- CONFIGURACION (v34)
----------------------------------------------------------------------
-- TouchOSC -> Micron: al mover un control se envia el NRPN correspondiente.
local SEND_NRPN=true
-- Micron -> TouchOSC: los NRPN que mande el Micron (knobs X/Y/Z...) mueven los controles.
local RECEIVE_NRPN=true
-- Canal MIDI de los NRPN: se elige en vivo con el fader de cada pagina
-- (1-16). midiChannel es 0-based (0 = canal 1). Cuando llega un volcado
-- SysEx valido del Micron/Miniak, el script detecta solo el canal por el
-- que hablo el sintetizador justo antes y ajusta el fader (ver
-- autoDetectChannel, mas abajo). Ya no existe el modo OMNI: mandar el
-- mismo NRPN por los 16 canales saturaba/colgaba interfaces MIDI reales
-- (Roland P-6, Novation 25SL mk2) sin ninguna ventaja.
local midiChannel=0
local lastRxChannel=nil    -- ultimo canal (0-based) del que llego un CC o PC
local autoReqChannel=nil   -- canal capturado EXACTAMENTE cuando llega el Program
                            -- Change que arma una peticion AUTO; evita que, mientras
                            -- se espera la respuesta SysEx, cualquier otro mensaje de
                            -- canal de por medio contamine lastRxChannel antes de
                            -- tiempo. REFRESH manual no tiene esa espera, asi que usa
                            -- lastRxChannel directamente, sin necesidad de capturarlo.
local autoDetectChannel    -- declarada aqui para que startAutoSync ya la vea; se define mas abajo
local DEBUG_NRPN=false          -- true = escribe cada NRPN en el log

-- Sincronizacion por SysEx (Micron -> TouchOSC) ---------------------
-- MODO APRENDIZAJE: AUTO empieza APAGADO (se activa con el boton AUTO). Con
-- AUTO apagado el log muestra lo que manda el Micron al cambiar de programa
-- (CC0, CC32 y Program Change) sin pedir nada.
local AUTO_REQUEST=false        -- pedir el patch al recibir un Program Change del Micron
local REQUEST_DELAY_MS=60       -- espera tras el ultimo Program Change (agrupa cambios rapidos)
local ECHO_MS=1500              -- tras pedir un patch, el Program Change que anuncia ESE mismo programa se ignora
-- El Micron da por "guardado" el patch que se le pide por SysEx. Con esto activo
-- no se pide un programa que hayas editado desde TouchOSC: se guarda una copia
-- de los controles al salir de el y se restaura al volver.
local PROTECT_EDITED=true
-- Como se pide el patch (F0 00 00 0E 22 41 ... F7):
--   5 = por ubicacion: 41 <banco> 00 <patch>  (formato del PDF Ion/Micron).
--       Banco y patch salen de lo que anuncia el Micron (CC0/CC32 y Program Change).
--   4 = "Edit bank" del PDF: 41 04 00 00. En tu Micron carga siempre
--       "The FM Police" y descarta los cambios: NO usar.
local REQUEST_MODE=5
local BANK_CC=32                -- 32 o 0: controlador que se toma como banco
local PC_OFFSET=0               -- se suma al Program Change para obtener el patch
local BANK_OFFSET=0             -- se suma al banco
local MODEL_IDS={34}            -- 34 (0x22) = Micron
local ACCEPT_MODEL={[34]=true,[38]=true}

-- Lectura del volcado ------------------------------------------------
-- false = posiciones del patch de Max (Miniak). true = posiciones del PDF
-- Ion/Micron en los campos donde ambos discrepan (osc 2/3 octava, semitono y
-- rango de pitch wheel, FM type, FM amount, freerun de las envolventes, tempo
-- sync del S&H). Cambialo si esos valores salen mal.
local LAYOUT_MICRON_PDF=false
-- Imprime en el log los bytes 93..108 del volcado (numeracion del PDF)
local DEBUG_SYSEX=false

local CHANNEL_FADER_IDS={"be0ef39d-0511-4c39-8ace-ad94469af306","89e95345-8b65-4207-8c2b-b26244f3b6be","3d02f1a4-8515-4135-afcf-c2f5d36e5a6b","226e46d8-fe22-439d-8e3d-9b6489243e59","219b60b3-5b33-45e7-8ab7-6d75966c783a","62d20099-8a05-4499-9938-ae086b3bc3b5","861cdeb4-c2db-4fd1-ac49-606817edd323","54df0875-8274-43c7-95e6-dfddb85c76f6","eea2c9da-5b29-4655-af85-84ab4069ed5e","5844a591-3d5e-4c71-854d-af60f6ff8eee","e2c49d30-2c14-47c9-bd18-f646b56ef048","d5eaf691-9210-4728-98c7-129ded2f3d00","6f6dbd8f-94ff-4d0e-a173-c1ea3a855f79","62ffa6bd-c17c-4e2b-95d7-171dce1ed5f8","60eb9c48-9dc0-49f8-a4a7-c177cd7ee6b2","cd572ee5-b01e-4067-b7ec-ab7d79415599"}
local CHANNEL_LBL_IDS={"dffa2ec1-09c3-448b-9e3c-5cce358c5c8f","8e83e0f4-a736-4425-8379-8f9417dcf5f2","1d1ad52a-8013-4d1f-ac4f-2bc1bee1d9af","d366d385-2fdd-4eaa-b76c-966302f9bfe0","33c5dca4-a3fc-4b8c-9831-f032dee7d792","fa72d1fc-f934-4983-9b69-c382a5549280","1953308d-c268-42cf-923b-05cf9cfd312c","8a2be500-15c0-46da-b2a8-7fb5d2d2ab34","050fd2cd-c28d-487c-a145-bb1bf76b7381","f9990abf-0092-46f0-ab0c-be57f23ecc6f","75e1cf4f-0464-4da3-ad23-b6e3338038a1","71dd9929-cf8b-42b6-90a2-bd2c1841f994","004dd7df-8962-41a9-9b2a-53693183a7d3","33222084-fa90-41bf-a726-1b8689d048fb","b9d2df9b-9abc-40a3-aa79-df24faf7b88d","7c0e598e-b16c-425f-b4ec-83f1308f7f86"}
local AUTO_BTN_IDS={"5d8dc6fd-e338-4266-bdc8-03ec033f07a0","42caa780-0f06-4b89-bf78-4910e774c649","903b54a3-b2df-44e5-8199-3cf62c51a55b","04d9aa39-7e1b-41d3-a62d-d387c355f372","049f9008-e8e0-4a9a-bf32-6fbe9d07e0be","be9f761f-844c-4d99-bcb2-c0af8545e035","459331f5-173b-433a-8b33-544bbf3055ff","50880e52-5a92-43e2-9f89-fc2782c4dd96","372192c4-67dc-452d-b8b3-2a691cf0cc3a","5421a941-166e-41f9-a41f-2a79ac57dfdf","e1dafb9f-18c2-424c-88d9-90182534d8ad","cb8a89e5-b78e-4af7-b41f-e8af1ab165ab","8862f35e-2afc-4010-9509-08d4d28c8dc9","bcf652c3-e818-4bb9-a087-dcc41237fe85","5d39e10b-0dd2-4fa8-9929-181c64dac0bc","29b2ea2c-e9b5-46e3-8d0e-c50118ee78d2"}
local STATUS_IDS={"b69fc433-1c69-456d-95ee-63c5a37f0ec3","cac48c08-9d6f-4445-bd33-afc18df536a7","8162832b-5bf0-4c2e-9e54-f8a1671e4722","8d74eb00-d768-4ba4-86fc-98f451234fae","a8ab6285-8e8d-417b-9db8-b72214f0d77f","34757728-2ec2-4c8e-a2a6-c4d425169b8f","f5a6e84d-5e26-4dad-b026-97b0e0facdc4","11d643bf-e17d-47d5-9966-e8caabc3d428","d3b8c78e-4f27-422a-93cf-b3a173ba3a32","03454cfd-bb24-47ac-a0c2-8ffe360a8d05","c1f7c5a6-7a4b-4965-9bad-9875a5f06b30","cf9d52e2-3ebf-461b-83fc-0046cc16e2a4","65c0c4b1-e345-4254-b58d-09ea4b21c9c1","c97df3b9-20fb-413a-8f2c-b41936feee9c","589a6287-b004-4312-983b-d89560768586","870a55d3-d2c9-4c02-819f-8b4e1348da61"}
local pendingRequest=false
local requestDue=0
local ignoreUntil=0
local bank0=nil
local bank32=nil
local curProg=nil
local curKey=nil          -- banco*128+patch del programa actual
local lastReqKey=nil
local expectUntil=0
local dirty={}            -- programas editados desde TouchOSC / knobs del Micron
local SNAP={}             -- copia de los controles de cada programa editado
local refreshArmedAt=0
local manualUntil=0

-- Ubicacion (banco, patch) del programa que anuncia el Micron
local function currentLocation()
  if curProg==nil then return nil end
  local b=bank32
  if BANK_CC==0 then b=bank0 end
  if b==nil then b=0 end
  b=b+BANK_OFFSET
  local p=curProg+PC_OFFSET
  if b<0 then b=0 end
  if b>127 then b=127 end
  if p<0 then p=0 end
  if p>127 then p=127 end
  return b,p
end

local function requestPatch(b,p)
  local body
  if REQUEST_MODE==4 then body={65,4,0,0} else body={65,b,0,p} end
  print(string.format('GET PATCH modo %d (bank=%d patch=%d)',REQUEST_MODE,b,p))
  for k=1,#MODEL_IDS do
    local m={240,0,0,14,MODEL_IDS[k]}
    for i=1,#body do m[#m+1]=body[i] end
    m[#m+1]=247
    sendMIDI(m)
    print('SYSEX OUT: '..table.concat(m,' '))
  end
  local now=getMillis()
  ignoreUntil=now+ECHO_MS
  expectUntil=now+2000
  lastReqKey=b*128+p
end

local params={
{"dummy::Unison",0,1,121,""},{"dummy::Portamento",0,1,135,""},{"dummy::OSCSync",0,1,278,""},{"dummy::OSCSyncType",0,1,280,""},{"dummy::FMAlgorithm",0,2,282,""},{"voice::Polyphony",0,1,120,""},{"voice::Unison",0,3,122,"addPrevious"},{"voice::UnisonDetune",0,100,128,""},{"voice::Portamento",0,2,152,"convertPortamento"},{"voice::PortaType",0,3,126,""},{"voice::PortaTime",0,127,136,""},{"voice::PitchWheel",0,1,144,"convertPitchWheel"},{"voice::AnalogDrift",0,100,160,""},{"voice::OSCSync",0,4,279,"convertOscSync"},{"voice::FMAmount",0,1000,328,""},{"voice::FMType",0,5,295,"convertFmType"},{"osc::[1]::Waveform",0,2,272,""},{"osc::[1]::Waveshape",-100,100,240,""},{"osc::[1]::Octave",-3,3,264,"convertOscOctave"},{"osc::[1]::Transpose",-7,7,268,"convertOscTranspose"},{"osc::[1]::Pitch",-999,999,200,""},{"osc::[1]::PWhlRange",0,12,274,""},{"osc::[1]::Level",0,100,360,""},{"osc::[1]::Balance",-50,50,400,""},{"osc::[2]::Waveform",0,2,284,""},{"osc::[2]::Waveshape",-100,100,248,""},{"osc::[2]::Octave",-3,3,296,"convertOscOctave"},{"osc::[2]::Transpose",-7,7,300,"convertOscTranspose"},{"osc::[2]::Pitch",-999,999,216,""},{"osc::[2]::PWhlRange",0,12,312,""},{"osc::[2]::Level",0,100,368,""},{"osc::[2]::Balance",-50,50,408,""},{"osc::[3]::Waveform",0,2,286,""},{"osc::[3]::Waveshape",-100,100,256,""},{"osc::[3]::Octave",-3,3,304,"convertOscOctave"},{"osc::[3]::Transpose",-7,7,308,"convertOscTranspose"},{"osc::[3]::Pitch",-999,999,232,""},{"osc::[3]::PWhlRange",0,12,316,""},{"osc::[3]::Level",0,100,376,""},{"osc::[3]::Balance",-50,50,416,""},{"pre::RingModLevel",0,100,384,""},{"pre::NoiseLevel",0,100,456,""},{"pre::RingModBalance",-50,50,424,""},{"pre::NoiseBalance",-50,50,440,""},{"pre::NoiseType",0,1,463,""},{"ext::Level",0,100,392,""},{"ext::Balance",-100,100,432,""},{"filter::SeriesLevel",0,100,448,""},{"filter::[1]::Type",0,20,608,"convertFilter"},{"filter::[1]::Frequency",0,920,512,""},{"filter::[1]::Resonance",0,100,536,""},{"filter::[1]::Keytrack",-100,200,576,""},{"filter::[1]::EnvAmount",-100,100,552,""},{"filter::[1]::Sign",0,1,696,""},{"filter::[1]::Level",0,100,664,""},{"filter::[1]::Pan",-100,100,704,""},{"filter::[2]::Offset",0,20,600,""},{"filter::[2]::Type",0,20,616,"convertFilter"},{"filter::[2]::Frequency::Absolute",0,920,528,""},{"filter::[2]::Frequency::Relative",-400,400,632,""},{"filter::[2]::Resonance",0,100,544,""},{"filter::[2]::Keytrack",-100,200,592,""},{"filter::[2]::EnvAmount",-100,100,560,""},{"filter::[2]::Level",0,100,672,""},{"filter::[2]::Pan",-100,100,712,""},{"filter::PreFilterLevel",0,100,680,""},{"filter::PreFilterPan",-100,100,720,""},{"filter::PreFilterSource",0,6,688,""},{"out::DriveType",0,6,776,""},{"out::DriveLevel",0,100,768,""},{"out::ProgramLevel",0,100,784,""},{"out::FxMix",-50,50,2240,"convertFxMix"},{"out::FxBalance",-50,50,2312,""},{"fx::Type[1]",0,6,2232,"convertFx1Type"},{"fx::[1]::A",-100,100,2248,""},{"fx::[1]::B",0,100,2256,""},{"fx::[1]::C",0,127,2264,""},{"fx::[1]::D",-100,100,2272,""},{"fx::[1]::E",0,3,2280,""},{"fx::[1]::F",0,5,2288,"convertFx1F"},{"fx::[1]::G",0,100,2296,"convertFx1G"},{"fx::[1]::H",0,24,2304,"convertFx1H"},{"fx::Type[2]",0,6,2320,""},{"fx::[2]::A",-100,680,736,""},{"fx::[2]::B",0,100,752,""},{"fx::[2]::C",0,127,1088,""},{"fx::[2]::D",-100,100,1104,""},{"fx::[2]::E",0,24,1112,""},{"env::[1]::AttackTime",0,255,840,""},{"env::[1]::AttackSlope",0,2,1056,""},{"env::[1]::DecayTime",0,255,864,""},{"env::[1]::DecaySlope",0,2,1060,""},{"env::[1]::SustainTime",0,256,920,""},{"env::[1]::SustainLevel",0,100,888,""},{"env::[1]::ReleaseTime",0,256,968,""},{"env::[1]::ReleaseSlope",0,2,1062,""},{"env::[1]::VelToEnv",0,100,1008,""},{"env::[1]::Reset",0,1,1036,""},{"env::[1]::Freerun",0,1,1038,""},{"env::[1]::Loop",0,3,1032,"convertEnvLoop"},{"env::[1]::SustainPedal",0,1,1035,""},{"env::[2]::AttackTime",0,255,848,""},{"env::[2]::AttackSlope",0,2,1064,""},{"env::[2]::DecayTime",0,255,872,""},{"env::[2]::DecaySlope",0,2,1068,""},{"env::[2]::SustainTime",0,256,936,""},{"env::[2]::SustainLevel",-100,100,896,""},{"env::[2]::ReleaseTime",0,256,984,""},{"env::[2]::ReleaseSlope",0,2,1070,""},{"env::[2]::VelToEnv",0,100,1016,""},{"env::[2]::Reset",0,1,1044,""},{"env::[2]::Freerun",0,1,1046,""},{"env::[2]::Loop",0,3,1040,"convertEnvLoop"},{"env::[2]::SustainPedal",0,1,1043,""},{"env::[3]::AttackTime",0,255,856,""},{"env::[3]::AttackSlope",0,2,1072,""},{"env::[3]::DecayTime",0,255,880,""},{"env::[3]::DecaySlope",0,2,1076,""},{"env::[3]::SustainTime",0,256,952,""},{"env::[3]::SustainLevel",-100,100,904,""},{"env::[3]::ReleaseTime",0,256,1000,""},{"env::[3]::ReleaseSlope",0,2,1078,""},{"env::[3]::VelToEnv",0,100,1024,""},{"env::[3]::Reset",0,1,1052,""},{"env::[3]::Freerun",0,1,1054,""},{"env::[3]::Loop",0,3,1048,"convertEnvLoop"},{"env::[3]::SustainPedal",0,1,1051,""},{"lfo::[1]::TempoSync",0,1,1200,"convertLfoTempoSync"},{"lfo::[1]::Rate::Absolute",0,1023,1128,""},{"lfo::[1]::Rate::Synced",0,24,1216,"convertLfoRateSynced"},{"lfo::[1]::Reset",0,6,1240,"convertLfoReset"},{"lfo::[1]::M1WheelToLfo",0,100,1152,""},{"lfo::[2]::TempoSync",0,1,1210,"convertLfoTempoSync"},{"lfo::[2]::Rate::Absolute",0,1023,1144,""},{"lfo::[2]::Rate::Synced",0,24,1224,"convertLfoRateSynced"},{"lfo::[2]::Reset",0,6,1244,"convertLfoReset"},{"lfo::[2]::M1WheelToLfo",0,100,1160,""},{"s/h::TempoSync",0,1,1214,"convertLfoTempoSync"},{"s/h::Rate::Absolute",0,1023,1184,""},{"s/h::Rate::Synced",0,24,1232,"convertLfoRateSynced"},{"s/h::Reset",0,6,1192,"convertLfoReset"},{"s/h::Input",0,35,1168,"convertSHInput"},{"s/h::Smoothing",1,100,1201,""},{"tracking::Input",0,35,1912,"convertTrackingInput"},{"tracking::NumPoints",0,1,1920,""},{"tracking::[-16]",-100,100,1928,""},{"tracking::[-15]",-100,100,1936,""},{"tracking::[-14]",-100,100,1944,""},{"tracking::[-13]",-100,100,1952,""},{"tracking::[-12]",-100,100,1960,""},{"tracking::[-11]",-100,100,1968,""},{"tracking::[-10]",-100,100,1976,""},{"tracking::[-9]",-100,100,1984,""},{"tracking::[-8]",-100,100,1992,""},{"tracking::[-7]",-100,100,2000,""},{"tracking::[-6]",-100,100,2008,""},{"tracking::[-5]",-100,100,2016,""},{"tracking::[-4]",-100,100,2024,""},{"tracking::[-3]",-100,100,2032,""},{"tracking::[-2]",-100,100,2040,""},{"tracking::[-1]",-100,100,2048,""},{"tracking::[0]",-100,100,2056,""},{"tracking::[1]",-100,100,2064,""},{"tracking::[2]",-100,100,2072,""},{"tracking::[3]",-100,100,2080,""},{"tracking::[4]",-100,100,2088,""},{"tracking::[5]",-100,100,2096,""},{"tracking::[6]",-100,100,2104,""},{"tracking::[7]",-100,100,2112,""},{"tracking::[8]",-100,100,2120,""},{"tracking::[9]",-100,100,2128,""},{"tracking::[10]",-100,100,2136,""},{"tracking::[11]",-100,100,2144,""},{"tracking::[12]",-100,100,2152,""},{"tracking::[13]",-100,100,2160,""},{"tracking::[14]",-100,100,2168,""},{"tracking::[15]",-100,100,2176,""},{"tracking::[16]",-100,100,2184,""},{"mod::[1]::Source",0,37,1336,"convertModSource"},{"mod::[1]::Destination",0,77,1432,"convertModDest"},{"mod::[1]::Level",-1000,1000,1536,""},{"mod::[1]::Offset",-1000,1000,1728,""},{"mod::[2]::Source",0,37,1344,"convertModSource"},{"mod::[2]::Destination",0,77,1440,"convertModDest"},{"mod::[2]::Level",-1000,1000,1552,""},{"mod::[2]::Offset",-1000,1000,1744,""},{"mod::[3]::Source",0,37,1352,"convertModSource"},{"mod::[3]::Destination",0,77,1448,"convertModDest"},{"mod::[3]::Level",-1000,1000,1568,""},{"mod::[3]::Offset",-1000,1000,1760,""},{"mod::[4]::Source",0,37,1360,"convertModSource"},{"mod::[4]::Destination",0,77,1456,"convertModDest"},{"mod::[4]::Level",-1000,1000,1584,""},{"mod::[4]::Offset",-1000,1000,1776,""},{"mod::[5]::Source",0,37,1368,"convertModSource"},{"mod::[5]::Destination",0,77,1464,"convertModDest"},{"mod::[5]::Level",-1000,1000,1600,""},{"mod::[5]::Offset",-1000,1000,1792,""},{"mod::[6]::Source",0,37,1376,"convertModSource"},{"mod::[6]::Destination",0,77,1472,"convertModDest"},{"mod::[6]::Level",-1000,1000,1616,""},{"mod::[6]::Offset",-1000,1000,1808,""},{"mod::[7]::Source",0,37,1384,"convertModSource"},{"mod::[7]::Destination",0,77,1480,"convertModDest"},{"mod::[7]::Level",-1000,1000,1632,""},{"mod::[7]::Offset",-1000,1000,1824,""},{"mod::[8]::Source",0,37,1392,"convertModSource"},{"mod::[8]::Destination",0,77,1488,"convertModDest"},{"mod::[8]::Level",-1000,1000,1648,""},{"mod::[8]::Offset",-1000,1000,1840,""},{"mod::[9]::Source",0,37,1400,"convertModSource"},{"mod::[9]::Destination",0,77,1496,"convertModDest"},{"mod::[9]::Level",-1000,1000,1664,""},{"mod::[9]::Offset",-1000,1000,1856,""},{"mod::[10]::Source",0,37,1408,"convertModSource"},{"mod::[10]::Destination",0,77,1504,"convertModDest"},{"mod::[10]::Level",-1000,1000,1680,""},{"mod::[10]::Offset",-1000,1000,1872,""},{"mod::[11]::Source",0,37,1416,"convertModSource"},{"mod::[11]::Destination",0,77,1512,"convertModDest"},{"mod::[11]::Level",-1000,1000,1696,""},{"mod::[11]::Offset",-1000,1000,1888,""},{"mod::[12]::Source",0,37,1424,"convertModSource"},{"mod::[12]::Destination",0,77,1520,"convertModDest"},{"mod::[12]::Level",-1000,1000,1712,""},{"mod::[12]::Offset",-1000,1000,1904,""},{"controller::X",0,219,792,"convertController"},{"controller::Y",0,219,800,"convertController"},{"controller::Z",0,219,808,"convertController"}}

local function addPrevious(raw,i,vals) return raw + 1 - vals[i-1] end
local function convertOscTranspose(v) return v - 7 end
local function convertOscOctave(v) return v - 3 end
local function convertPitchWheel(v) return math.abs(v - 1) end
local function convertPortamento(v,i,vals) local a=addPrevious(v,i,vals); local l={0,2,1}; return l[a+1] or a end
local function convertOscSync(v,i,vals) local s=v+2*vals[i-1]+4*vals[i-2]; local l={3,4,1,2,0}; return l[s+1] or v end
local function convertFmType(v,i,vals) return 3*v+2-vals[i-1] end
local function convertFilter(v) local l={0,3,1,7,11,5,2,4,6,9,8,20,16,17,13,14,15,10,12,18,19}; return l[v+1] or v end
local function convertFxMix(v) return math.floor(v/2) end
local fx1Type=0
local function convertFx1Type(v) local l={0,4,5,2,3,1,6}; fx1Type=l[v+1] or v; return fx1Type end
local function convertFx1F(v) if fx1Type==0 or fx1Type==4 or fx1Type==6 then return v else return 1-v end end
local function convertFx1G(v) if fx1Type==4 then return 1-v else return v end end
local function convertFx1H(v) return 24-v end
local function convertEnvLoop(v) local l={1,2,3,0}; return l[v+1] or v end
local function convertLfoTempoSync(v) return 1-v end
local function convertLfoReset(v) local l={0,1,2,3,6,4,5}; return l[v+1] or v end
local function convertLfoRateSynced(v) return 24-v end
local function mapSH(v) local l={0,34,5,23,24,25,31,4,1,2,3,9,10,13,14,7,8,11,12,17,18,21,22,15,16,19,20,30,29,27,26,32,33,28,0,36,37,38,39,40}; return l[v+1] or 4 end
local function convertSHInput(v) return mapSH(v) end
local function convertTrackingInput(v) local l={33,34,5,23,24,25,32,4,1,2,3,9,10,13,14,7,8,11,12,17,18,21,22,15,16,19,20,31,30,29,27,26,28,0,35,36,37,38,39,40}; return l[v+1] or 4 end
local function convertModSource(v) local l={0,36,37,6,24,25,26,33,5,2,3,4,10,11,14,15,8,9,12,17,18,19,22,15,16,17,20,21,32,31,30,28,27,34,35,29,1,38,39,40}; return l[v+1] or v end
local function convertModDest(v) local l={0,1,4,7,10,5,8,11,6,9,12,3,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,71,72,73,74,75,76,77,36,37,38,39,40,5,44,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70}; return l[v+1] or v end
local function convertController(v) return v end

-- Octava y semitono de los osciladores: el SysEx los guarda SIN signo
-- (octava 0..6, semitono 0..14) y el convertidor resta 3 / 7. Hay que leerlos
-- con el rango crudo (antes se leian como con signo y salian mal).
local RAW_RANGE={
  ["osc::[1]::Octave"]={0,6},["osc::[2]::Octave"]={0,6},["osc::[3]::Octave"]={0,6},
  ["osc::[1]::Transpose"]={0,14},["osc::[2]::Transpose"]={0,14},["osc::[3]::Transpose"]={0,14}
}
-- Diferencias de posicion entre el patch de Max y el PDF Ion/Micron (en bits)
local PDF_SHIFT={
  ["osc::[2]::Octave"]=8,["osc::[2]::Transpose"]=8,
  ["osc::[3]::Octave"]=8,["osc::[3]::Transpose"]=8,
  ["osc::[2]::PWhlRange"]=8,["osc::[3]::PWhlRange"]=8,
  ["voice::FMType"]=8,["voice::FMAmount"]=8,
  ["env::[1]::Freerun"]=1,["env::[2]::Freerun"]=1,["env::[3]::Freerun"]=1,
  ["s/h::TempoSync"]=-2
}
for i=1,#params do
  local p=params[i]
  local r=RAW_RANGE[p[1]]
  if r then p[2]=r[1]; p[3]=r[2] end
  if LAYOUT_MICRON_PDF then
    local d=PDF_SHIFT[p[1]]
    if d then p[4]=p[4]+d end
  end
end

local CONV={
  addPrevious=addPrevious,
  convertOscTranspose=convertOscTranspose,convertOscOctave=convertOscOctave,
  convertPitchWheel=convertPitchWheel,convertPortamento=convertPortamento,
  convertOscSync=convertOscSync,convertFmType=convertFmType,convertFilter=convertFilter,
  convertFxMix=convertFxMix,convertFx1Type=convertFx1Type,convertFx1F=convertFx1F,
  convertFx1G=convertFx1G,convertFx1H=convertFx1H,convertEnvLoop=convertEnvLoop,
  convertLfoTempoSync=convertLfoTempoSync,convertLfoReset=convertLfoReset,
  convertLfoRateSynced=convertLfoRateSynced,convertSHInput=convertSHInput,
  convertTrackingInput=convertTrackingInput,convertModSource=convertModSource,
  convertModDest=convertModDest,convertController=convertController
}

-- direccion OSC de cada parametro (p.ej. "osc::[1]::Level" -> "/osc/1/Level")
local pathOf={}
for i=1,#params do
  local p=params[i][1]:gsub('::','/'):gsub('%[',''):gsub('%]','')
  if p:sub(1,4)=='s/h/' then p='s-h/'..p:sub(5) end
  pathOf[i]='/'..p
end

----------------------------------------------------------------------
-- Decodificacion SysEx (7 bits -> 8 bits)
----------------------------------------------------------------------
-- ceil(log2(n)) exacto. OJO: en TouchOSC (Lua 5.1) math.log(x,2) NO admite
-- base, devuelve el logaritmo natural, por eso no se usa.
local function bitsFor(n)
  local w=0
  while 2^w<n do w=w+1 end
  return w
end

local function decode7to8(msg)
  local s=1
  local e=#msg
  if msg[1]==240 then s=2 end
  if msg[e]==247 then e=e-1 end
  if e-s+1<9 then return nil,'demasiado corto' end
  if msg[s]~=0 or msg[s+1]~=0 or msg[s+2]~=14 then return nil,'fabricante distinto de 00 00 0E' end
  local model=msg[s+3]
  if not ACCEPT_MODEL[model] then return nil,'modelo '..model..' no aceptado' end
  if msg[s+4]~=1 then return nil,'opcode '..msg[s+4]..' (se esperaba 01 = program dump)' end
  s=s+8
  local out={}
  local i=s
  while i<=e do
    local msb=msg[i]
    for j=1,7 do
      local b=msg[i+j]
      if (not b) or i+j>e then break end
      local bit=math.floor(msb/(2^(7-j)))%2
      out[#out+1]=b+bit*128
    end
    i=i+8
  end
  return out,nil,model
end

local function readBits(content,off,minv,maxv)
  local byte=math.floor(off/8)+1
  local width=bitsFor(math.max(maxv+1,-minv))
  if minv<0 then width=width+1 end
  local result=content[byte] or 0
  if width>8 then result=result+256*(content[byte-1] or 0); width=16
  elseif width<8 and minv>=0 then result=math.floor(result/(2^(off%8)))%2^width end
  if minv<0 and result>=2^(width-1) then result=-(2^width-result) end
  if result<minv then result=minv end; if result>maxv then result=maxv end
  return result
end

----------------------------------------------------------------------
-- Tablas generadas a partir del layout (IDs de control por direccion OSC)
--   {id,"F",min,max,indice de pagina}  fader/radial (o boton on/off con rango)
--   {id,"E",valor,valor,pagina}  boton de un grupo de opciones
----------------------------------------------------------------------

-- direccion OSC del control -> numero NRPN "raiz" del Micron (hoja "Alesis Micron Complete NRPN")
local NRPN={
["/osc/1/Level"]=29,
["/osc/1/Waveform"]=11,
["/osc/1/Pitch"]=15,
["/osc/1/Waveshape"]=12,
["/osc/1/Balance"]=35,
["/osc/1/Octave"]=13,
["/osc/1/Transpose"]=14,
["/osc/2/Level"]=30,
["/osc/2/Pitch"]=21,
["/osc/2/Waveshape"]=18,
["/osc/2/Balance"]=36,
["/filter/1/Frequency"]=44,
["/filter/1/Resonance"]=45,
["/filter/1/Level"]=54,
["/filter/2/Frequency/Absolute"]=158,
["/filter/2/Resonance"]=51,
["/filter/2/Level"]=55,
["/env/1/AttackTime"]=66,
["/env/1/DecayTime"]=68,
["/env/1/SustainLevel"]=71,
["/env/1/ReleaseTime"]=72,
["/osc/2/Waveform"]=17,
["/osc/2/Octave"]=19,
["/osc/2/Transpose"]=20,
["/osc/3/Level"]=31,
["/osc/3/Waveform"]=23,
["/osc/3/Pitch"]=27,
["/osc/3/Waveshape"]=24,
["/osc/3/Balance"]=37,
["/pre/NoiseType"]=42,
["/pre/NoiseBalance"]=39,
["/pre/NoiseLevel"]=33,
["/pre/RingModBalance"]=38,
["/pre/RingModLevel"]=32,
["/ext/Balance"]=40,
["/ext/Level"]=34,
["/osc/3/Octave"]=25,
["/osc/3/Transpose"]=26,
["/filter/1/Type"]=43,
["/filter/1/Sign"]=61,
["/filter/1/Keytrack"]=46,
["/filter/1/EnvAmount"]=47,
["/filter/2/Keytrack"]=52,
["/filter/2/EnvAmount"]=53,
["/filter/SeriesLevel"]=41,
["/env/2/AttackTime"]=79,
["/env/2/DecayTime"]=81,
["/env/2/SustainLevel"]=84,
["/env/2/ReleaseTime"]=85,
["/filter/2/Type"]=49,
["/env/1/AttackSlope"]=67,
["/env/1/DecaySlope"]=69,
["/env/1/SustainTime"]=70,
["/env/1/ReleaseSlope"]=73,
["/env/1/VelToEnv"]=74,
["/env/1/Reset"]=75,
["/env/1/Freerun"]=76,
["/env/1/Loop"]=77,
["/env/2/AttackSlope"]=80,
["/env/2/DecaySlope"]=82,
["/env/2/SustainTime"]=83,
["/env/2/ReleaseSlope"]=86,
["/env/2/VelToEnv"]=87,
["/env/2/Reset"]=88,
["/env/2/Freerun"]=89,
["/env/2/Loop"]=90,
["/env/3/AttackTime"]=92,
["/env/3/AttackSlope"]=93,
["/env/3/DecayTime"]=94,
["/env/3/DecaySlope"]=95,
["/env/3/SustainLevel"]=97,
["/env/3/SustainTime"]=96,
["/env/3/ReleaseTime"]=98,
["/env/3/ReleaseSlope"]=99,
["/env/3/VelToEnv"]=100,
["/env/3/Reset"]=101,
["/env/3/Freerun"]=102,
["/env/3/Loop"]=103,
["/lfo/1/Rate/Synced"]=159,
["/lfo/1/TempoSync"]=105,
["/lfo/1/Rate/Absolute"]=106,
["/lfo/1/M1WheelToLfo"]=108,
["/lfo/1/Reset"]=107,
["/lfo/2/TempoSync"]=109,
["/lfo/2/Rate/Absolute"]=110,
["/lfo/2/M1WheelToLfo"]=112,
["/lfo/2/Reset"]=111,
["/lfo/2/Rate/Synced"]=160,
["/s-h/Reset"]=115,
["/s-h/Input"]=116,
["/s-h/Rate/Synced"]=161,
["/s-h/TempoSync"]=113,
["/s-h/Rate/Absolute"]=114,
["/s-h/Smoothing"]=117,
["/tracking/NumPoints"]=120,
["/tracking/1"]=138,
["/tracking/2"]=139,
["/tracking/3"]=140,
["/tracking/4"]=141,
["/tracking/8"]=145,
["/tracking/5"]=142,
["/tracking/6"]=143,
["/tracking/7"]=144,
["/tracking/16"]=153,
["/tracking/13"]=150,
["/tracking/14"]=151,
["/tracking/15"]=152,
["/tracking/12"]=149,
["/tracking/11"]=148,
["/tracking/10"]=147,
["/tracking/9"]=146,
["/tracking/0"]=137,
["/tracking/-16"]=121,
["/tracking/-15"]=122,
["/tracking/-14"]=123,
["/tracking/-13"]=124,
["/tracking/-9"]=128,
["/tracking/-12"]=125,
["/tracking/-11"]=126,
["/tracking/-10"]=127,
["/tracking/-1"]=136,
["/tracking/-4"]=133,
["/tracking/-3"]=134,
["/tracking/-2"]=135,
["/tracking/-5"]=132,
["/tracking/-6"]=131,
["/tracking/-7"]=130,
["/tracking/-8"]=129,
["/tracking/Input"]=118,
["/mod/1/Source"]=180,
["/mod/1/Destination"]=181,
["/mod/1/Level"]=182,
["/mod/1/Offset"]=183,
["/mod/2/Source"]=184,
["/mod/2/Destination"]=185,
["/mod/2/Level"]=186,
["/mod/2/Offset"]=187,
["/mod/3/Source"]=188,
["/mod/3/Destination"]=189,
["/mod/3/Level"]=190,
["/mod/3/Offset"]=191,
["/mod/4/Source"]=192,
["/mod/4/Destination"]=193,
["/mod/4/Level"]=194,
["/mod/4/Offset"]=195,
["/mod/5/Source"]=196,
["/mod/5/Destination"]=197,
["/mod/5/Level"]=198,
["/mod/5/Offset"]=199,
["/mod/6/Source"]=200,
["/mod/6/Destination"]=201,
["/mod/6/Level"]=202,
["/mod/6/Offset"]=203,
["/mod/7/Source"]=204,
["/mod/7/Destination"]=205,
["/mod/7/Level"]=206,
["/mod/7/Offset"]=207,
["/mod/8/Source"]=208,
["/mod/8/Destination"]=209,
["/mod/8/Level"]=210,
["/mod/8/Offset"]=211,
["/voice/Polyphony"]=0,
["/voice/Unison"]=1,
["/voice/UnisonDetune"]=2,
["/voice/Portamento"]=3,
["/voice/PortaType"]=4,
["/voice/PortaTime"]=5,
["/voice/OSCSync"]=8,
["/voice/FMType"]=10,
["/voice/FMAmount"]=9,
["/voice/PitchWheel"]=6,
["/out/DriveType"]=62,
["/out/DriveLevel"]=63,
["/out/FxMix"]=65,
["/out/ProgramLevel"]=64,
["/out/FxBalance"]=230,
}

local CTL={
["/osc/1/Level"]={{"c96d7c66-b290-11f1-a48f-020000000000","F",0,100,0},{"c96e463c-b290-11f1-97ff-020000000000","F",0,100,2}},
["/osc/1/Waveform"]={{"c96d8030-b290-11f1-8008-020000000000","E",0,0,0},{"c96d8134-b290-11f1-90bf-020000000000","E",1,1,0},{"c96d81d4-b290-11f1-a4ae-020000000000","E",2,2,0}},
["/osc/1/Pitch"]={{"c96d8562-b290-11f1-89dd-020000000000","F",-250,250,0}},
["/osc/1/Waveshape"]={{"c96d86b6-b290-11f1-a1e0-020000000000","F",-100,100,0}},
["/osc/1/Balance"]={{"c96d880a-b290-11f1-adb0-020000000000","F",-50,50,0},{"c96e472c-b290-11f1-ac84-020000000000","F",-50,50,2}},
["/osc/1/Octave"]={{"c96d892c-b290-11f1-8867-020000000000","E",-3,-3,0},{"c96d89ae-b290-11f1-bc47-020000000000","E",-2,-2,0},{"c96d8a44-b290-11f1-a263-020000000000","E",-1,-1,0},{"c96d8ab2-b290-11f1-802a-020000000000","E",0,0,0},{"c96d8b2a-b290-11f1-908c-020000000000","E",1,1,0},{"c96d8b8e-b290-11f1-9543-020000000000","E",2,2,0},{"c96d8bfc-b290-11f1-b1f9-020000000000","E",3,3,0}},
["/osc/1/Transpose"]={{"c96d916a-b290-11f1-b78c-020000000000","E",-7,-7,0},{"c96d91d8-b290-11f1-bff8-020000000000","E",-6,-6,0},{"c96d9246-b290-11f1-9661-020000000000","E",-5,-5,0},{"c96d92b4-b290-11f1-98ef-020000000000","E",-4,-4,0},{"c96d9322-b290-11f1-ab39-020000000000","E",-3,-3,0},{"c96d9390-b290-11f1-ad13-020000000000","E",-2,-2,0},{"c96d9408-b290-11f1-b308-020000000000","E",-1,-1,0},{"c96d9818-b290-11f1-8aea-020000000000","E",0,0,0},{"c96d9886-b290-11f1-80a6-020000000000","E",1,1,0},{"c96d98f4-b290-11f1-80fc-020000000000","E",2,2,0},{"c96d9958-b290-11f1-b7a3-020000000000","E",3,3,0},{"c96d99bc-b290-11f1-a4c6-020000000000","E",4,4,0},{"c96d9a2a-b290-11f1-9696-020000000000","E",5,5,0},{"c96d9a98-b290-11f1-b325-020000000000","E",6,6,0},{"c96d9e4e-b290-11f1-9bc6-020000000000","E",7,7,0}},
["/osc/2/Level"]={{"c96da524-b290-11f1-b537-020000000000","F",0,100,0},{"c96e4a6a-b290-11f1-85e3-020000000000","F",0,100,2}},
["/osc/2/Pitch"]={{"c96da7c2-b290-11f1-903b-020000000000","F",-250,250,0}},
["/osc/2/Waveshape"]={{"c96da8bc-b290-11f1-ab6e-020000000000","F",-100,100,0}},
["/osc/2/Balance"]={{"c96da9c0-b290-11f1-ad32-020000000000","F",-50,50,0},{"c96e4b8c-b290-11f1-b4be-020000000000","F",-50,50,2}},
["/filter/1/Frequency"]={{"c96dbdac-b290-11f1-912f-020000000000","F",0,920,0},{"c96e023a-b290-11f1-8f5b-020000000000","F",0,920,1},{"c96e3c78-b290-11f1-af65-020000000000","F",0,920,2}},
["/filter/1/Resonance"]={{"c96dbe42-b290-11f1-88d3-020000000000","F",0,100,0},{"c96e02b2-b290-11f1-81b2-020000000000","F",0,100,1},{"c96e3d86-b290-11f1-b6ac-020000000000","F",0,100,2}},
["/filter/1/Level"]={{"c96dbed8-b290-11f1-ad99-020000000000","F",0,100,0},{"c96e0316-b290-11f1-93ee-020000000000","F",0,100,1},{"c96e3ab6-b290-11f1-8a90-020000000000","F",0,100,2}},
["/filter/2/Frequency/Absolute"]={{"c96dc1da-b290-11f1-b0ab-020000000000","F",0,920,0},{"c96e065e-b290-11f1-aa70-020000000000","F",0,920,1},{"c96e4358-b290-11f1-9bca-020000000000","F",0,920,2}},
["/filter/2/Resonance"]={{"c96dc25c-b290-11f1-b2d0-020000000000","F",0,100,0},{"c96e06cc-b290-11f1-8e17-020000000000","F",0,100,1},{"c96e4448-b290-11f1-926c-020000000000","F",0,100,2}},
["/filter/2/Level"]={{"c96dc2ca-b290-11f1-96ea-020000000000","F",0,100,0},{"c96e074e-b290-11f1-acc2-020000000000","F",0,100,1},{"c96e413c-b290-11f1-89fa-020000000000","F",0,100,2}},
["/env/1/AttackTime"]={{"c96dc5d6-b290-11f1-b805-020000000000","F",0,255,0},{"c96e0a46-b290-11f1-bff8-020000000000","F",0,255,1},{"c96e7620-b290-11f1-b4ee-020000000000","F",0,255,3}},
["/env/1/DecayTime"]={{"c96dc6d0-b290-11f1-9fe6-020000000000","F",0,255,0},{"c96e0b36-b290-11f1-a2a3-020000000000","F",0,255,1},{"c96e7ba2-b290-11f1-9d3a-020000000000","F",0,255,3}},
["/env/1/SustainLevel"]={{"c96dc7c0-b290-11f1-90b9-020000000000","F",0,100,0},{"c96e0c26-b290-11f1-ba3c-020000000000","F",0,100,1},{"c96e812e-b290-11f1-a02e-020000000000","F",0,100,3}},
["/env/1/ReleaseTime"]={{"c96dc8c4-b290-11f1-87c3-020000000000","F",0,255,0},{"c96e0d2a-b290-11f1-be53-020000000000","F",0,255,1},{"c96e857a-b290-11f1-993f-020000000000","F",0,255,3}},
["/osc/2/Waveform"]={{"c96dd166-b290-11f1-bb79-020000000000","E",0,0,0},{"c96dd1e8-b290-11f1-912b-020000000000","E",1,1,0},{"c96dd260-b290-11f1-8daa-020000000000","E",2,2,0}},
["/osc/2/Octave"]={{"c96dd2d8-b290-11f1-a739-020000000000","E",-3,-3,0},{"c96dd33c-b290-11f1-a162-020000000000","E",-2,-2,0},{"c96dd3a0-b290-11f1-afa5-020000000000","E",-1,-1,0},{"c96dd3fa-b290-11f1-9833-020000000000","E",0,0,0},{"c96dd45e-b290-11f1-8dc1-020000000000","E",1,1,0},{"c96dd4c2-b290-11f1-badc-020000000000","E",2,2,0},{"c96dd530-b290-11f1-a7f0-020000000000","E",3,3,0}},
["/osc/2/Transpose"]={{"c96dd594-b290-11f1-ab66-020000000000","E",-7,-7,0},{"c96dd5f8-b290-11f1-87cb-020000000000","E",-6,-6,0},{"c96dd666-b290-11f1-8f6a-020000000000","E",-5,-5,0},{"c96dd6e8-b290-11f1-841e-020000000000","E",-4,-4,0},{"c96dd760-b290-11f1-abda-020000000000","E",-3,-3,0},{"c96dd7c4-b290-11f1-b0d3-020000000000","E",-2,-2,0},{"c96dd828-b290-11f1-a842-020000000000","E",-1,-1,0},{"c96dd88c-b290-11f1-94b5-020000000000","E",0,0,0},{"c96dd8e6-b290-11f1-b5a0-020000000000","E",1,1,0},{"c96dd94a-b290-11f1-a7eb-020000000000","E",2,2,0},{"c96dd9a4-b290-11f1-9bd2-020000000000","E",3,3,0},{"c96dda08-b290-11f1-a074-020000000000","E",4,4,0},{"c96dda6c-b290-11f1-b000-020000000000","E",5,5,0},{"c96ddad0-b290-11f1-8033-020000000000","E",6,6,0},{"c96ddb34-b290-11f1-9162-020000000000","E",7,7,0}},
["/osc/3/Level"]={{"c96ddecc-b290-11f1-bb64-020000000000","F",0,100,1},{"c96e4d76-b290-11f1-9ffa-020000000000","F",0,100,2}},
["/osc/3/Waveform"]={{"c96ddf58-b290-11f1-ac10-020000000000","E",0,0,1},{"c96ddfb2-b290-11f1-9ee0-020000000000","E",1,1,1},{"c96de020-b290-11f1-b5cb-020000000000","E",2,2,1}},
["/osc/3/Pitch"]={{"c96de2a0-b290-11f1-ae40-020000000000","F",-250,250,1}},
["/osc/3/Waveshape"]={{"c96de390-b290-11f1-b256-020000000000","F",-100,100,1}},
["/osc/3/Balance"]={{"c96de494-b290-11f1-aa87-020000000000","F",-50,50,1},{"c96e4e70-b290-11f1-ac2a-020000000000","F",-50,50,2}},
["/pre/NoiseType"]={{"c96df42a-b290-11f1-9c63-020000000000","E",0,0,1},{"c96df498-b290-11f1-abce-020000000000","E",1,1,1}},
["/pre/NoiseBalance"]={{"c96df5e2-b290-11f1-8c9a-020000000000","F",-50,50,1}},
["/pre/NoiseLevel"]={{"c96df6e6-b290-11f1-8993-020000000000","F",0,100,1}},
["/pre/RingModBalance"]={{"c96df9c0-b290-11f1-9399-020000000000","F",-50,50,1}},
["/pre/RingModLevel"]={{"c96dfaba-b290-11f1-bf32-020000000000","F",0,100,1}},
["/ext/Balance"]={{"c96dfdbc-b290-11f1-a040-020000000000","F",-100,100,1}},
["/ext/Level"]={{"c96dfeb6-b290-11f1-ab31-020000000000","F",0,100,1}},
["/osc/3/Octave"]={{"c96e1662-b290-11f1-8802-020000000000","E",-3,-3,1},{"c96e16c6-b290-11f1-8736-020000000000","E",-2,-2,1},{"c96e1734-b290-11f1-ae56-020000000000","E",-1,-1,1},{"c96e178e-b290-11f1-b148-020000000000","E",0,0,1},{"c96e17f2-b290-11f1-94ae-020000000000","E",1,1,1},{"c96e1874-b290-11f1-a814-020000000000","E",2,2,1},{"c96e18ce-b290-11f1-bbae-020000000000","E",3,3,1}},
["/osc/3/Transpose"]={{"c96e1928-b290-11f1-a0aa-020000000000","E",-7,-7,1},{"c96e198c-b290-11f1-9fdc-020000000000","E",-6,-6,1},{"c96e19f0-b290-11f1-a6de-020000000000","E",-5,-5,1},{"c96e1a5e-b290-11f1-b9df-020000000000","E",-4,-4,1},{"c96e1acc-b290-11f1-9037-020000000000","E",-3,-3,1},{"c96e1b3a-b290-11f1-95b9-020000000000","E",-2,-2,1},{"c96e1b94-b290-11f1-ba95-020000000000","E",-1,-1,1},{"c96e1bf8-b290-11f1-9ad6-020000000000","E",0,0,1},{"c96e1c52-b290-11f1-a727-020000000000","E",1,1,1},{"c96e1cb6-b290-11f1-9258-020000000000","E",2,2,1},{"c96e1d10-b290-11f1-b354-020000000000","E",3,3,1},{"c96e1d7e-b290-11f1-964f-020000000000","E",4,4,1},{"c96e1de2-b290-11f1-a345-020000000000","E",5,5,1},{"c96e1e3c-b290-11f1-a4b4-020000000000","E",6,6,1},{"c96e1ebe-b290-11f1-9f88-020000000000","E",7,7,1}},
["/filter/1/Type"]={{"c96e20d0-b290-11f1-ad9b-020000000000","E",16,16,2},{"c96e21ac-b290-11f1-a5c9-020000000000","E",17,17,2},{"c96e2288-b290-11f1-a072-020000000000","E",18,18,2},{"c96e2364-b290-11f1-8375-020000000000","E",19,19,2},{"c96e2526-b290-11f1-97d5-020000000000","E",13,13,2},{"c96e2634-b290-11f1-9337-020000000000","E",14,14,2},{"c96e2710-b290-11f1-bb54-020000000000","E",15,15,2},{"c96e2882-b290-11f1-b695-020000000000","E",20,20,2},{"c96e29d6-b290-11f1-8b18-020000000000","E",1,1,2},{"c96e2ab2-b290-11f1-9116-020000000000","E",2,2,2},{"c96e2b98-b290-11f1-bda0-020000000000","E",3,3,2},{"c96e2c74-b290-11f1-a1ef-020000000000","E",4,4,2},{"c96e2d46-b290-11f1-b08a-020000000000","E",5,5,2},{"c96e2e22-b290-11f1-85d5-020000000000","E",6,6,2},{"c96e2f76-b290-11f1-88d2-020000000000","E",7,7,2},{"c96e3048-b290-11f1-9b45-020000000000","E",8,8,2},{"c96e3124-b290-11f1-a1ce-020000000000","E",9,9,2},{"c96e31f6-b290-11f1-a83f-020000000000","E",10,10,2},{"c96e334a-b290-11f1-8f14-020000000000","E",11,11,2},{"c96e3430-b290-11f1-8bd8-020000000000","E",12,12,2},{"c96e376e-b290-11f1-8ebc-020000000000","E",0,0,2}},
["/filter/1/Sign"]={{"c96e3606-b290-11f1-aeeb-020000000000","F",0,1,2}},
["/filter/1/Keytrack"]={{"c96e38cc-b290-11f1-8b4e-020000000000","F",-100,100,2}},
["/filter/1/EnvAmount"]={{"c96e3a3e-b290-11f1-a74a-020000000000","F",-100,100,2}},
["/filter/2/Keytrack"]={{"c96e3f48-b290-11f1-9da3-020000000000","F",-100,100,2}},
["/filter/2/EnvAmount"]={{"c96e40b0-b290-11f1-8baa-020000000000","F",-100,100,2}},
["/filter/SeriesLevel"]={{"c96e44d4-b290-11f1-a65d-020000000000","F",0,100,2}},
["/env/2/AttackTime"]={{"c96e50fa-b290-11f1-9bcc-020000000000","F",0,255,2},{"c96e9484-b290-11f1-99d6-020000000000","F",0,255,3}},
["/env/2/DecayTime"]={{"c96e526c-b290-11f1-914e-020000000000","F",0,255,2},{"c96e99fc-b290-11f1-b06c-020000000000","F",0,255,3}},
["/env/2/SustainLevel"]={{"c96e535c-b290-11f1-8426-020000000000","F",0,100,2},{"c96e9f6a-b290-11f1-96cf-020000000000","F",0,100,3}},
["/env/2/ReleaseTime"]={{"c96e53ca-b290-11f1-8fff-020000000000","F",0,255,2},{"c96ea398-b290-11f1-bacb-020000000000","F",0,255,3}},
["/filter/2/Type"]={{"c96e5d70-b290-11f1-8523-020000000000","E",16,16,2},{"c96e5e6a-b290-11f1-b06a-020000000000","E",17,17,2},{"c96e5f46-b290-11f1-8b3e-020000000000","E",18,18,2},{"c96e602c-b290-11f1-bc05-020000000000","E",19,19,2},{"c96e6176-b290-11f1-b379-020000000000","E",13,13,2},{"c96e625c-b290-11f1-bf78-020000000000","E",14,14,2},{"c96e6338-b290-11f1-b262-020000000000","E",15,15,2},{"c96e648c-b290-11f1-881f-020000000000","E",20,20,2},{"c96e65f4-b290-11f1-8092-020000000000","E",1,1,2},{"c96e66f8-b290-11f1-aab3-020000000000","E",2,2,2},{"c96e67ca-b290-11f1-8a14-020000000000","E",3,3,2},{"c96e689c-b290-11f1-b7cb-020000000000","E",4,4,2},{"c96e6982-b290-11f1-91d2-020000000000","E",5,5,2},{"c96e6a54-b290-11f1-9758-020000000000","E",6,6,2},{"c96e6bc6-b290-11f1-86d5-020000000000","E",7,7,2},{"c96e6ca2-b290-11f1-ae9a-020000000000","E",8,8,2},{"c96e6d74-b290-11f1-83eb-020000000000","E",9,9,2},{"c96e6e5a-b290-11f1-a3c4-020000000000","E",10,10,2},{"c96e6fae-b290-11f1-88f7-020000000000","E",11,11,2},{"c96e708a-b290-11f1-9d1d-020000000000","E",12,12,2},{"c96e7224-b290-11f1-bc1e-020000000000","E",0,0,2}},
["/env/1/AttackSlope"]={{"c96e7724-b290-11f1-b980-020000000000","E",0,0,3},{"c96e7800-b290-11f1-a9c4-020000000000","E",1,1,3},{"c96e78dc-b290-11f1-be55-020000000000","E",2,2,3}},
["/env/1/DecaySlope"]={{"c96e7ca6-b290-11f1-aa60-020000000000","E",0,0,3},{"c96e7d82-b290-11f1-ae15-020000000000","E",1,1,3},{"c96e7e68-b290-11f1-b339-020000000000","E",2,2,3}},
["/env/1/SustainTime"]={{"c96e821e-b290-11f1-adc7-020000000000","E",256,256,3},{"c96e841c-b290-11f1-a39f-020000000000","F",0,255,3}},
["/env/1/ReleaseSlope"]={{"c96e8674-b290-11f1-bd95-020000000000","E",0,0,3},{"c96e876e-b290-11f1-a113-020000000000","E",1,1,3},{"c96e884a-b290-11f1-afbe-020000000000","E",2,2,3}},
["/env/1/VelToEnv"]={{"c96e8aac-b290-11f1-b54b-020000000000","F",0,100,3}},
["/env/1/Reset"]={{"c96e8b92-b290-11f1-98ee-020000000000","F",0,1,3}},
["/env/1/Freerun"]={{"c96e8d18-b290-11f1-bc8c-020000000000","F",0,1,3}},
["/env/1/Loop"]={{"c96e8e76-b290-11f1-afc0-020000000000","E",0,0,3},{"c96e8fde-b290-11f1-94db-020000000000","E",1,1,3},{"c96e90b0-b290-11f1-99f3-020000000000","E",2,2,3},{"c96e91aa-b290-11f1-96be-020000000000","E",3,3,3}},
["/env/2/AttackSlope"]={{"c96e9574-b290-11f1-bd9b-020000000000","E",0,0,3},{"c96e9664-b290-11f1-a447-020000000000","E",1,1,3},{"c96e9736-b290-11f1-ba31-020000000000","E",2,2,3}},
["/env/2/DecaySlope"]={{"c96e9ae2-b290-11f1-84e7-020000000000","E",0,0,3},{"c96e9bb4-b290-11f1-b7e0-020000000000","E",1,1,3},{"c96e9c90-b290-11f1-bd85-020000000000","E",2,2,3}},
["/env/2/SustainTime"]={{"c96ea050-b290-11f1-ade5-020000000000","E",256,256,3},{"c96ea230-b290-11f1-92ea-020000000000","F",0,255,3}},
["/env/2/ReleaseSlope"]={{"c96ea488-b290-11f1-ab46-020000000000","E",0,0,3},{"c96ea564-b290-11f1-9370-020000000000","E",1,1,3},{"c96ea640-b290-11f1-af1a-020000000000","E",2,2,3}},
["/env/2/VelToEnv"]={{"c96ea8d4-b290-11f1-a1ce-020000000000","F",0,100,3}},
["/env/2/Reset"]={{"c96ea9ce-b290-11f1-b279-020000000000","F",0,1,3}},
["/env/2/Freerun"]={{"c96eab2c-b290-11f1-872e-020000000000","F",0,1,3}},
["/env/2/Loop"]={{"c96eac94-b290-11f1-b40f-020000000000","E",0,0,3},{"c96eadfc-b290-11f1-aa87-020000000000","E",1,1,3},{"c96eaed8-b290-11f1-8601-020000000000","E",2,2,3},{"c96eafbe-b290-11f1-8fde-020000000000","E",3,3,3}},
["/env/3/AttackTime"]={{"c96ebd2e-b290-11f1-bbe4-020000000000","F",0,255,4}},
["/env/3/AttackSlope"]={{"c96ebe1e-b290-11f1-8bda-020000000000","E",0,0,4},{"c96ebefa-b290-11f1-bd1c-020000000000","E",1,1,4},{"c96ebfe0-b290-11f1-99aa-020000000000","E",2,2,4}},
["/env/3/DecayTime"]={{"c96ec2a6-b290-11f1-9701-020000000000","F",0,255,4}},
["/env/3/DecaySlope"]={{"c96ec396-b290-11f1-884c-020000000000","E",0,0,4},{"c96ec47c-b290-11f1-a4d6-020000000000","E",1,1,4},{"c96ec6b6-b290-11f1-8ede-020000000000","E",2,2,4}},
["/env/3/SustainLevel"]={{"c96ec9fe-b290-11f1-ae1a-020000000000","F",0,100,4}},
["/env/3/SustainTime"]={{"c96ecb16-b290-11f1-ac36-020000000000","E",256,256,4},{"c96ecd1e-b290-11f1-9516-020000000000","F",0,255,4}},
["/env/3/ReleaseTime"]={{"c96eceae-b290-11f1-b4e1-020000000000","F",0,255,4}},
["/env/3/ReleaseSlope"]={{"c96ecfbc-b290-11f1-a40e-020000000000","E",0,0,4},{"c96ed098-b290-11f1-b039-020000000000","E",1,1,4},{"c96ed174-b290-11f1-b3a8-020000000000","E",2,2,4}},
["/env/3/VelToEnv"]={{"c96ed3d6-b290-11f1-b8da-020000000000","F",0,100,4}},
["/env/3/Reset"]={{"c96ed4d0-b290-11f1-a361-020000000000","F",0,1,4}},
["/env/3/Freerun"]={{"c96ed67e-b290-11f1-8de2-020000000000","F",0,1,4}},
["/env/3/Loop"]={{"c96ed7e6-b290-11f1-bdb2-020000000000","E",0,0,4},{"c96ed944-b290-11f1-9b79-020000000000","E",1,1,4},{"c96eda2a-b290-11f1-85b5-020000000000","E",2,2,4},{"c96edafc-b290-11f1-8fb1-020000000000","E",3,3,4}},
["/lfo/1/Rate/Synced"]={{"c96edb60-b290-11f1-8b01-020000000000","E",0,0,4},{"c96edcc8-b290-11f1-a806-020000000000","E",3,3,4},{"c96edda4-b290-11f1-91d6-020000000000","E",6,6,4},{"c96ede9e-b290-11f1-819e-020000000000","E",9,9,4},{"c96edf7a-b290-11f1-a207-020000000000","E",12,12,4},{"c96ee060-b290-11f1-aae7-020000000000","E",14,14,4},{"c96ee13c-b290-11f1-b0c7-020000000000","E",15,15,4},{"c96ee240-b290-11f1-bb18-020000000000","E",11,11,4},{"c96ee330-b290-11f1-add7-020000000000","E",17,17,4},{"c96ee40c-b290-11f1-8a15-020000000000","E",18,18,4},{"c96ee4fc-b290-11f1-9828-020000000000","E",20,20,4},{"c96ee5ce-b290-11f1-a974-020000000000","E",21,21,4}},
["/lfo/1/TempoSync"]={{"c96ee6be-b290-11f1-8c0b-020000000000","E",1,1,4},{"c96ee790-b290-11f1-b3b4-020000000000","E",0,0,4}},
["/lfo/1/Rate/Absolute"]={{"c96ee7fe-b290-11f1-a8fc-020000000000","F",0,1023,4}},
["/lfo/1/M1WheelToLfo"]={{"c96eea2e-b290-11f1-9cd5-020000000000","F",0,100,4}},
["/lfo/1/Reset"]={{"c96eeca4-b290-11f1-a97a-020000000000","E",0,0,4},{"c96eedbc-b290-11f1-a94a-020000000000","E",2,2,4},{"c96eeeac-b290-11f1-be89-020000000000","E",4,4,4},{"c96eef92-b290-11f1-8853-020000000000","E",1,1,4},{"c96ef082-b290-11f1-bac7-020000000000","E",3,3,4},{"c96ef172-b290-11f1-9a2d-020000000000","E",5,5,4}},
["/lfo/2/TempoSync"]={{"c96efb5e-b290-11f1-a0b0-020000000000","E",1,1,4},{"c96efc3a-b290-11f1-b882-020000000000","E",0,0,4}},
["/lfo/2/Rate/Absolute"]={{"c96efca8-b290-11f1-bd05-020000000000","F",0,1023,4}},
["/lfo/2/M1WheelToLfo"]={{"c96efec4-b290-11f1-90e6-020000000000","F",0,100,4}},
["/lfo/2/Reset"]={{"c96f013a-b290-11f1-b484-020000000000","E",0,0,4},{"c96f0234-b290-11f1-87e6-020000000000","E",2,2,4},{"c96f0310-b290-11f1-b73a-020000000000","E",4,4,4},{"c96f03f6-b290-11f1-98ad-020000000000","E",1,1,4},{"c96f04c8-b290-11f1-b209-020000000000","E",3,3,4},{"c96f05ae-b290-11f1-bf98-020000000000","E",5,5,4}},
["/lfo/2/Rate/Synced"]={{"c96f061c-b290-11f1-8532-020000000000","E",12,12,4},{"c96f0680-b290-11f1-b8e6-020000000000","E",11,11,4},{"c96f06da-b290-11f1-a1e3-020000000000","E",9,9,4},{"c96f0752-b290-11f1-b716-020000000000","E",6,6,4},{"c96f07ac-b290-11f1-93d3-020000000000","E",3,3,4},{"c96f081a-b290-11f1-ac26-020000000000","E",0,0,4},{"c96f0892-b290-11f1-88fc-020000000000","E",14,14,4},{"c96f08f6-b290-11f1-bae8-020000000000","E",15,15,4},{"c96f0950-b290-11f1-ac71-020000000000","E",17,17,4},{"c96f09b4-b290-11f1-8cdb-020000000000","E",18,18,4},{"c96f0a0e-b290-11f1-a225-020000000000","E",20,20,4},{"c96f0a7c-b290-11f1-8ba0-020000000000","E",21,21,4}},
["/s-h/Reset"]={{"c96f13d2-b290-11f1-91e4-020000000000","E",5,5,5},{"c96f1436-b290-11f1-94b8-020000000000","E",3,3,5},{"c96f1490-b290-11f1-b305-020000000000","E",1,1,5},{"c96f1508-b290-11f1-a327-020000000000","E",4,4,5},{"c96f1562-b290-11f1-9900-020000000000","E",2,2,5},{"c96f15bc-b290-11f1-83c6-020000000000","E",0,0,5}},
["/s-h/Input"]={{"c96f16a2-b290-11f1-83b7-020000000000","E",0,0,5},{"c96f1800-b290-11f1-a998-020000000000","E",1,1,5},{"c96f18f0-b290-11f1-88c7-020000000000","E",2,2,5},{"c96f19ea-b290-11f1-8470-020000000000","E",3,3,5},{"c96f1ac6-b290-11f1-b47b-020000000000","E",5,5,5},{"c96f1c1a-b290-11f1-a5bc-020000000000","E",6,6,5},{"c96f1d6e-b290-11f1-a8ff-020000000000","E",15,15,5},{"c96f1eea-b290-11f1-b81b-020000000000","E",16,16,5},{"c96f203e-b290-11f1-8888-020000000000","E",17,17,5},{"c96f2188-b290-11f1-b6b2-020000000000","E",18,18,5},{"c96f22dc-b290-11f1-b463-020000000000","E",19,19,5},{"c96f2430-b290-11f1-a130-020000000000","E",20,20,5},{"c96f25ac-b290-11f1-913b-020000000000","E",21,21,5},{"c96f2714-b290-11f1-acae-020000000000","E",22,22,5},{"c96f2872-b290-11f1-93ec-020000000000","E",23,23,5},{"c96f29da-b290-11f1-9719-020000000000","E",24,24,5},{"c96f2b2e-b290-11f1-8e0b-020000000000","E",25,25,5},{"c96f2c82-b290-11f1-b0ef-020000000000","E",26,26,5},{"c96f2de0-b290-11f1-b628-020000000000","E",27,27,5},{"c96f2f3e-b290-11f1-9b59-020000000000","E",28,28,5},{"c96f30a6-b290-11f1-911c-020000000000","E",29,29,5},{"c96f3218-b290-11f1-804a-020000000000","E",30,30,5},{"c96f3376-b290-11f1-8604-020000000000","E",31,31,5},{"c96f34d4-b290-11f1-88c3-020000000000","E",32,32,5},{"c96f3650-b290-11f1-a79c-020000000000","E",33,33,5},{"c96f37ae-b290-11f1-abfa-020000000000","E",34,34,5},{"c96f3902-b290-11f1-9849-020000000000","E",35,35,5},{"c96f3a4c-b290-11f1-b0d4-020000000000","E",4,4,5},{"c96f3bbe-b290-11f1-b6f4-020000000000","E",7,7,5},{"c96f3d30-b290-11f1-9ead-020000000000","E",8,8,5},{"c96f3e98-b290-11f1-a9a1-020000000000","E",9,9,5},{"c96f4000-b290-11f1-8fcb-020000000000","E",10,10,5},{"c96f415e-b290-11f1-94a1-020000000000","E",11,11,5},{"c96f42b2-b290-11f1-8988-020000000000","E",12,12,5},{"c96f4424-b290-11f1-be6c-020000000000","E",13,13,5},{"c96f458c-b290-11f1-9c20-020000000000","E",14,14,5}},
["/s-h/Rate/Synced"]={{"c96f4a00-b290-11f1-9d94-020000000000","E",3,3,5},{"c96f4ad2-b290-11f1-995f-020000000000","E",6,6,5},{"c96f4bae-b290-11f1-816d-020000000000","E",9,9,5},{"c96f4c8a-b290-11f1-8f28-020000000000","E",12,12,5},{"c96f4d7a-b290-11f1-b60c-020000000000","E",15,15,5},{"c96f4e60-b290-11f1-8b4a-020000000000","E",18,18,5}},
["/s-h/TempoSync"]={{"c96f4f3c-b290-11f1-b2de-020000000000","E",1,1,5},{"c96f5018-b290-11f1-b93d-020000000000","E",0,0,5}},
["/s-h/Rate/Absolute"]={{"c96f507c-b290-11f1-bf41-020000000000","F",0,1023,5}},
["/s-h/Smoothing"]={{"c96f563a-b290-11f1-aba3-020000000000","F",1,100,5}},
["/tracking/NumPoints"]={{"c96f63c8-b290-11f1-ad1a-020000000000","E",1,1,6},{"c96f64d6-b290-11f1-bd45-020000000000","E",0,0,6}},
["/tracking/1"]={{"c96f6698-b290-11f1-9855-020000000000","F",-100,100,6}},
["/tracking/2"]={{"c96f672e-b290-11f1-a459-020000000000","F",-100,100,6}},
["/tracking/3"]={{"c96f67a6-b290-11f1-bac3-020000000000","F",-100,100,6}},
["/tracking/4"]={{"c96f6828-b290-11f1-a846-020000000000","F",-100,100,6}},
["/tracking/8"]={{"c96f68a0-b290-11f1-81e9-020000000000","F",-100,100,6}},
["/tracking/5"]={{"c96f690e-b290-11f1-9b3f-020000000000","F",-100,100,6}},
["/tracking/6"]={{"c96f6a3a-b290-11f1-82a0-020000000000","F",-100,100,6}},
["/tracking/7"]={{"c96f6ac6-b290-11f1-a7b6-020000000000","F",-100,100,6}},
["/tracking/16"]={{"c96f6b48-b290-11f1-945b-020000000000","F",-100,100,6}},
["/tracking/13"]={{"c96f6bb6-b290-11f1-b1f0-020000000000","F",-100,100,6}},
["/tracking/14"]={{"c96f6c2e-b290-11f1-acbf-020000000000","F",-100,100,6}},
["/tracking/15"]={{"c96f6ca6-b290-11f1-861e-020000000000","F",-100,100,6}},
["/tracking/12"]={{"c96f6d64-b290-11f1-95a5-020000000000","F",-100,100,6}},
["/tracking/11"]={{"c96f6dd2-b290-11f1-9713-020000000000","F",-100,100,6}},
["/tracking/10"]={{"c96f6e54-b290-11f1-8ae3-020000000000","F",-100,100,6}},
["/tracking/9"]={{"c96f6ed6-b290-11f1-9a0c-020000000000","F",-100,100,6}},
["/tracking/0"]={{"c96f6f44-b290-11f1-93b4-020000000000","F",-100,100,6}},
["/tracking/-16"]={{"c96f6fc6-b290-11f1-89c0-020000000000","F",-100,100,6}},
["/tracking/-15"]={{"c96f7048-b290-11f1-90e9-020000000000","F",-100,100,6}},
["/tracking/-14"]={{"c96f70d4-b290-11f1-9c34-020000000000","F",-100,100,6}},
["/tracking/-13"]={{"c96f7156-b290-11f1-8ec9-020000000000","F",-100,100,6}},
["/tracking/-9"]={{"c96f71ce-b290-11f1-81a7-020000000000","F",-100,100,6}},
["/tracking/-12"]={{"c96f7250-b290-11f1-b897-020000000000","F",-100,100,6}},
["/tracking/-11"]={{"c96f72be-b290-11f1-b1d4-020000000000","F",-100,100,6}},
["/tracking/-10"]={{"c96f732c-b290-11f1-b116-020000000000","F",-100,100,6}},
["/tracking/-1"]={{"c96f73ae-b290-11f1-869b-020000000000","F",-100,100,6}},
["/tracking/-4"]={{"c96f741c-b290-11f1-bb4c-020000000000","F",-100,100,6}},
["/tracking/-3"]={{"c96f7494-b290-11f1-b8c0-020000000000","F",-100,100,6}},
["/tracking/-2"]={{"c96f750c-b290-11f1-8f3d-020000000000","F",-100,100,6}},
["/tracking/-5"]={{"c96f7584-b290-11f1-878a-020000000000","F",-100,100,6}},
["/tracking/-6"]={{"c96f75f2-b290-11f1-a774-020000000000","F",-100,100,6}},
["/tracking/-7"]={{"c96f766a-b290-11f1-b36a-020000000000","F",-100,100,6}},
["/tracking/-8"]={{"c96f76d8-b290-11f1-b6e1-020000000000","F",-100,100,6}},
["/tracking/Input"]={{"c96f77c8-b290-11f1-871f-020000000000","E",0,0,6},{"c96f793a-b290-11f1-851c-020000000000","E",1,1,6},{"c96f7a0c-b290-11f1-8396-020000000000","E",2,2,6},{"c96f7afc-b290-11f1-9987-020000000000","E",3,3,6},{"c96f7bf6-b290-11f1-8284-020000000000","E",5,5,6},{"c96f7d40-b290-11f1-8904-020000000000","E",6,6,6},{"c96f7e94-b290-11f1-99c3-020000000000","E",15,15,6},{"c96f7ff2-b290-11f1-abe0-020000000000","E",16,16,6},{"c96f8164-b290-11f1-bf7c-020000000000","E",17,17,6},{"c96f82c2-b290-11f1-aed7-020000000000","E",18,18,6},{"c96f842a-b290-11f1-9ef7-020000000000","E",19,19,6},{"c96f8588-b290-11f1-97dd-020000000000","E",20,20,6},{"c96f86dc-b290-11f1-bccf-020000000000","E",21,21,6},{"c96f886c-b290-11f1-8265-020000000000","E",22,22,6},{"c96f89c0-b290-11f1-b571-020000000000","E",23,23,6},{"c96f8b14-b290-11f1-a848-020000000000","E",24,24,6},{"c96f8c68-b290-11f1-a0ec-020000000000","E",25,25,6},{"c96f8dbc-b290-11f1-97cb-020000000000","E",26,26,6},{"c96f8f24-b290-11f1-a0d3-020000000000","E",27,27,6},{"c96f908c-b290-11f1-8a59-020000000000","E",28,28,6},{"c96f91f4-b290-11f1-8da2-020000000000","E",29,29,6},{"c96f9366-b290-11f1-b00c-020000000000","E",30,30,6},{"c96f94d8-b290-11f1-945f-020000000000","E",31,31,6},{"c96f9622-b290-11f1-ba14-020000000000","E",32,32,6},{"c96f976c-b290-11f1-b8bc-020000000000","E",33,33,6},{"c96f98de-b290-11f1-8fa8-020000000000","E",34,34,6},{"c96f9a64-b290-11f1-95bd-020000000000","E",35,35,6},{"c96f9bc2-b290-11f1-88ba-020000000000","E",4,4,6},{"c96f9d0c-b290-11f1-8460-020000000000","E",7,7,6},{"c96f9ea6-b290-11f1-b89f-020000000000","E",8,8,6},{"c96f9ff0-b290-11f1-850d-020000000000","E",9,9,6},{"c96fa14e-b290-11f1-bcac-020000000000","E",10,10,6},{"c96fa2c0-b290-11f1-a339-020000000000","E",11,11,6},{"c96fa414-b290-11f1-ad90-020000000000","E",12,12,6},{"c96fa57c-b290-11f1-a2b4-020000000000","E",13,13,6},{"c96fa6ee-b290-11f1-b799-020000000000","E",14,14,6}},
["/mod/1/Source"]={{"c96fb4cc-b290-11f1-9667-020000000000","E",1,1,7},{"c96fb62a-b290-11f1-9ec2-020000000000","E",2,2,7},{"c96fb710-b290-11f1-be2b-020000000000","E",3,3,7},{"c96fb814-b290-11f1-bdca-020000000000","E",4,4,7},{"c96fb904-b290-11f1-a041-020000000000","E",6,6,7},{"c96fba6c-b290-11f1-95e6-020000000000","E",7,7,7},{"c96fbbac-b290-11f1-996a-020000000000","E",16,16,7},{"c96fbd1e-b290-11f1-a8e3-020000000000","E",17,17,7},{"c96fbe86-b290-11f1-989e-020000000000","E",18,18,7},{"c96fbfd0-b290-11f1-a5bc-020000000000","E",19,19,7},{"c96fc12e-b290-11f1-ac2c-020000000000","E",20,20,7},{"c96fc2aa-b290-11f1-8057-020000000000","E",21,21,7},{"c96fc444-b290-11f1-88f8-020000000000","E",22,22,7},{"c96fc5fc-b290-11f1-bc2f-020000000000","E",23,23,7},{"c96fc78c-b290-11f1-a05c-020000000000","E",24,24,7},{"c96fc908-b290-11f1-bb32-020000000000","E",25,25,7},{"c96fca5c-b290-11f1-b41d-020000000000","E",26,26,7},{"c96fcc00-b290-11f1-bd42-020000000000","E",27,27,7},{"c96fcd7c-b290-11f1-ba16-020000000000","E",28,28,7},{"c96fcf16-b290-11f1-aab7-020000000000","E",29,29,7},{"c96fd0d8-b290-11f1-9dda-020000000000","E",30,30,7},{"c96fd25e-b290-11f1-915e-020000000000","E",31,31,7},{"c96fd3bc-b290-11f1-ab74-020000000000","E",32,32,7},{"c96fd51a-b290-11f1-8ca7-020000000000","E",34,34,7},{"c96fd696-b290-11f1-89ad-020000000000","E",35,35,7},{"c96fd7fe-b290-11f1-b23d-020000000000","E",36,36,7},{"c96fd966-b290-11f1-b382-020000000000","E",37,37,7},{"c96fdace-b290-11f1-9e82-020000000000","E",5,5,7},{"c96fdc72-b290-11f1-aecb-020000000000","E",8,8,7},{"c96fddc6-b290-11f1-9856-020000000000","E",9,9,7},{"c96fdf10-b290-11f1-b27e-020000000000","E",10,10,7},{"c96fe08c-b290-11f1-a533-020000000000","E",11,11,7},{"c96fe212-b290-11f1-9a57-020000000000","E",12,12,7},{"c96fe384-b290-11f1-8f8b-020000000000","E",13,13,7},{"c96fe51e-b290-11f1-92c0-020000000000","E",14,14,7},{"c96fe6b8-b290-11f1-9629-020000000000","E",15,15,7},{"c96fe99c-b290-11f1-9ab2-020000000000","E",0,0,7}},
["/mod/1/Destination"]={{"c96fea00-b290-11f1-8ed0-020000000000","E",25,25,7},{"c96feb9a-b290-11f1-b464-020000000000","E",29,29,7},{"c96fed16-b290-11f1-97bd-020000000000","E",30,30,7},{"c96fee7e-b290-11f1-9b39-020000000000","E",10,10,7},{"c96feff0-b290-11f1-94f7-020000000000","E",6,6,7},{"c96ff16c-b290-11f1-b3f0-020000000000","E",9,9,7},{"c96ff2f2-b290-11f1-ad2b-020000000000","E",12,12,7},{"c96ff450-b290-11f1-af97-020000000000","E",13,13,7},{"c96ff5d6-b290-11f1-b2cc-020000000000","E",14,14,7},{"c96ff73e-b290-11f1-be7d-020000000000","E",15,15,7},{"c96ff888-b290-11f1-a00e-020000000000","E",21,21,7},{"c96ff9e6-b290-11f1-b3b5-020000000000","E",33,33,7},{"c96ffb4e-b290-11f1-be0c-020000000000","E",34,34,7},{"c96ffcb6-b290-11f1-8243-020000000000","E",31,31,7},{"c96ffe0a-b290-11f1-a537-020000000000","E",37,37,7},{"c96fff68-b290-11f1-b385-020000000000","E",35,35,7},{"c97000da-b290-11f1-af17-020000000000","E",36,36,7},{"c970021a-b290-11f1-a583-020000000000","E",28,28,7},{"c9700382-b290-11f1-a0ce-020000000000","E",5,5,7},{"c97004e0-b290-11f1-aedd-020000000000","E",4,4,7},{"c970062a-b290-11f1-878f-020000000000","E",8,8,7},{"c9700774-b290-11f1-a3b0-020000000000","E",7,7,7},{"c97008aa-b290-11f1-84c2-020000000000","E",11,11,7},{"c9700f8a-b290-11f1-ba22-020000000000","E",19,19,7},{"c97010f2-b290-11f1-b9c3-020000000000","E",20,20,7},{"c970126e-b290-11f1-8f0f-020000000000","E",32,32,7},{"c97013b8-b290-11f1-af45-020000000000","E",39,39,7},{"c97014a8-b290-11f1-9da6-020000000000","E",40,40,7},{"c9701688-b290-11f1-9263-020000000000","E",16,16,7},{"c97017d2-b290-11f1-9b94-020000000000","E",22,22,7},{"c9701930-b290-11f1-a096-020000000000","E",23,23,7},{"c9701ab6-b290-11f1-bc1e-020000000000","E",38,38,7},{"c9701c1e-b290-11f1-9521-020000000000","E",24,24,7},{"c9701d9a-b290-11f1-abc6-020000000000","E",17,17,7},{"c9701ee4-b290-11f1-822a-020000000000","E",18,18,7},{"c9702042-b290-11f1-8010-020000000000","E",41,41,7},{"c9702182-b290-11f1-9734-020000000000","E",63,63,7},{"c97022f4-b290-11f1-95ca-020000000000","E",67,67,7},{"c970243e-b290-11f1-a0ab-020000000000","E",68,68,7},{"c9702592-b290-11f1-8706-020000000000","E",50,50,7},{"c97026f0-b290-11f1-b17f-020000000000","E",51,51,7},{"c9702844-b290-11f1-870e-020000000000","E",52,52,7},{"c970298e-b290-11f1-b9cc-020000000000","E",53,53,7},{"c9702ae2-b290-11f1-a829-020000000000","E",54,54,7},{"c9702c36-b290-11f1-8970-020000000000","E",59,59,7},{"c9702d80-b290-11f1-8fc4-020000000000","E",60,60,7},{"c9702ed4-b290-11f1-9be6-020000000000","E",61,61,7},{"c9703032-b290-11f1-9f44-020000000000","E",69,69,7},{"c97031a4-b290-11f1-a3ac-020000000000","E",62,62,7},{"c9703302-b290-11f1-98b8-020000000000","E",65,65,7},{"c9703460-b290-11f1-9cbe-020000000000","E",66,66,7},{"c97035aa-b290-11f1-b546-020000000000","E",64,64,7},{"c97036e0-b290-11f1-bcfa-020000000000","E",55,55,7},{"c970382a-b290-11f1-bfc2-020000000000","E",56,56,7},{"c970397e-b290-11f1-b7be-020000000000","E",57,57,7},{"c9703adc-b290-11f1-8fc9-020000000000","E",58,58,7},{"c9703c58-b290-11f1-92d2-020000000000","E",70,70,7},{"c9703da2-b290-11f1-a311-020000000000","E",71,71,7},{"c9703f0a-b290-11f1-b182-020000000000","E",72,72,7},{"c9704054-b290-11f1-b285-020000000000","E",75,75,7},{"c970418a-b290-11f1-b7ed-020000000000","E",76,76,7},{"c97042e8-b290-11f1-95fa-020000000000","E",73,73,7},{"c9704432-b290-11f1-933e-020000000000","E",74,74,7},{"c9704586-b290-11f1-a461-020000000000","E",77,77,7},{"c97046e4-b290-11f1-82fc-020000000000","E",27,27,7},{"c9704874-b290-11f1-88a3-020000000000","E",26,26,7},{"c97049dc-b290-11f1-a5e1-020000000000","E",1,1,7},{"c9704ab8-b290-11f1-8578-020000000000","E",2,2,7},{"c9704bf8-b290-11f1-8607-020000000000","E",3,3,7},{"c9704d9c-b290-11f1-9d07-020000000000","E",0,0,7},{"c9704e00-b290-11f1-8090-020000000000","E",47,47,7},{"c9704f4a-b290-11f1-b7ff-020000000000","E",48,48,7},{"c970508a-b290-11f1-887e-020000000000","E",49,49,7},{"c97051e8-b290-11f1-b740-020000000000","E",42,42,7},{"c970533c-b290-11f1-be4b-020000000000","E",43,43,7},{"c97054a4-b290-11f1-86ec-020000000000","E",44,44,7},{"c9705576-b290-11f1-8aa2-020000000000","E",45,45,7},{"c97056b6-b290-11f1-b5c4-020000000000","E",46,46,7}},
["/mod/1/Level"]={{"c9705954-b290-11f1-aa61-020000000000","F",-1000,1000,7}},
["/mod/1/Offset"]={{"c97059cc-b290-11f1-9f66-020000000000","F",-1000,1000,7}},
["/mod/2/Source"]={{"c9706df4-b290-11f1-b602-020000000000","E",1,1,8},{"c9706f34-b290-11f1-ae24-020000000000","E",2,2,8},{"c9707010-b290-11f1-9d81-020000000000","E",3,3,8},{"c9707100-b290-11f1-90e4-020000000000","E",4,4,8},{"c97071c8-b290-11f1-a280-020000000000","E",6,6,8},{"c9707312-b290-11f1-86f3-020000000000","E",7,7,8},{"c9707466-b290-11f1-bb0d-020000000000","E",16,16,8},{"c97075ce-b290-11f1-bc70-020000000000","E",17,17,8},{"c970772c-b290-11f1-a994-020000000000","E",18,18,8},{"c9707880-b290-11f1-b0b9-020000000000","E",19,19,8},{"c97079d4-b290-11f1-90e8-020000000000","E",20,20,8},{"c9707b1e-b290-11f1-a1c3-020000000000","E",21,21,8},{"c9707c72-b290-11f1-97e0-020000000000","E",22,22,8},{"c9707dbc-b290-11f1-b01f-020000000000","E",23,23,8},{"c9707f10-b290-11f1-b209-020000000000","E",24,24,8},{"c9708064-b290-11f1-862e-020000000000","E",25,25,8},{"c97081b8-b290-11f1-91d6-020000000000","E",26,26,8},{"c9708320-b290-11f1-8063-020000000000","E",27,27,8},{"c970847e-b290-11f1-a704-020000000000","E",28,28,8},{"c97085dc-b290-11f1-8954-020000000000","E",29,29,8},{"c9708726-b290-11f1-ad82-020000000000","E",30,30,8},{"c970887a-b290-11f1-b435-020000000000","E",31,31,8},{"c97089e2-b290-11f1-b144-020000000000","E",32,32,8},{"c9708b2c-b290-11f1-b999-020000000000","E",34,34,8},{"c9708c76-b290-11f1-8f19-020000000000","E",35,35,8},{"c9708dd4-b290-11f1-bc50-020000000000","E",36,36,8},{"c9708f28-b290-11f1-a901-020000000000","E",37,37,8},{"c970907c-b290-11f1-88a6-020000000000","E",5,5,8},{"c97091da-b290-11f1-9700-020000000000","E",8,8,8},{"c970931a-b290-11f1-b7aa-020000000000","E",9,9,8},{"c9709464-b290-11f1-b577-020000000000","E",10,10,8},{"c97095b8-b290-11f1-83a2-020000000000","E",11,11,8},{"c97096f8-b290-11f1-af3d-020000000000","E",12,12,8},{"c970982e-b290-11f1-864b-020000000000","E",13,13,8},{"c9709982-b290-11f1-9efc-020000000000","E",14,14,8},{"c9709c3e-b290-11f1-a436-020000000000","E",15,15,8},{"c9709e50-b290-11f1-b731-020000000000","E",0,0,8}},
["/mod/2/Destination"]={{"c9709ebe-b290-11f1-94fd-020000000000","E",25,25,8},{"c970a012-b290-11f1-bd0e-020000000000","E",29,29,8},{"c970a17a-b290-11f1-be02-020000000000","E",30,30,8},{"c970a2f6-b290-11f1-aa0a-020000000000","E",10,10,8},{"c970a454-b290-11f1-93d4-020000000000","E",6,6,8},{"c970a59e-b290-11f1-bc8b-020000000000","E",9,9,8},{"c970a724-b290-11f1-872b-020000000000","E",12,12,8},{"c970a86e-b290-11f1-b3ab-020000000000","E",13,13,8},{"c970a9ae-b290-11f1-88c3-020000000000","E",14,14,8},{"c970ab16-b290-11f1-91aa-020000000000","E",15,15,8},{"c970ac60-b290-11f1-95c8-020000000000","E",21,21,8},{"c970adb4-b290-11f1-94b2-020000000000","E",33,33,8},{"c970af12-b290-11f1-a94a-020000000000","E",34,34,8},{"c970b066-b290-11f1-9d43-020000000000","E",31,31,8},{"c970b1ce-b290-11f1-9a51-020000000000","E",37,37,8},{"c970b318-b290-11f1-ac04-020000000000","E",35,35,8},{"c970b476-b290-11f1-a40d-020000000000","E",36,36,8},{"c970b5ca-b290-11f1-afc5-020000000000","E",28,28,8},{"c970b746-b290-11f1-a74d-020000000000","E",5,5,8},{"c970b89a-b290-11f1-9fb1-020000000000","E",4,4,8},{"c970ba16-b290-11f1-b749-020000000000","E",8,8,8},{"c970bb92-b290-11f1-8846-020000000000","E",7,7,8},{"c970bcfa-b290-11f1-98f8-020000000000","E",11,11,8},{"c970be9e-b290-11f1-bb07-020000000000","E",19,19,8},{"c970c01a-b290-11f1-bbca-020000000000","E",20,20,8},{"c970c182-b290-11f1-b12c-020000000000","E",32,32,8},{"c970c2ea-b290-11f1-a655-020000000000","E",39,39,8},{"c970c3f8-b290-11f1-a300-020000000000","E",40,40,8},{"c970c5ce-b290-11f1-be7d-020000000000","E",16,16,8},{"c970c722-b290-11f1-80c8-020000000000","E",22,22,8},{"c970c89e-b290-11f1-a22b-020000000000","E",23,23,8},{"c970ca1a-b290-11f1-b9a7-020000000000","E",38,38,8},{"c970cb82-b290-11f1-943d-020000000000","E",24,24,8},{"c970ccf4-b290-11f1-a99b-020000000000","E",17,17,8},{"c970ce52-b290-11f1-9657-020000000000","E",18,18,8},{"c970cfa6-b290-11f1-9b2a-020000000000","E",41,41,8},{"c970d122-b290-11f1-9042-020000000000","E",63,63,8},{"c970d2d0-b290-11f1-ba8a-020000000000","E",67,67,8},{"c970d4b0-b290-11f1-bef5-020000000000","E",68,68,8},{"c970d636-b290-11f1-94c3-020000000000","E",50,50,8},{"c970d794-b290-11f1-a842-020000000000","E",51,51,8},{"c970d8f2-b290-11f1-9c1e-020000000000","E",52,52,8},{"c970da64-b290-11f1-93c5-020000000000","E",53,53,8},{"c970dbcc-b290-11f1-b7c1-020000000000","E",54,54,8},{"c970dd2a-b290-11f1-8639-020000000000","E",59,59,8},{"c970de74-b290-11f1-b3d0-020000000000","E",60,60,8},{"c970dfbe-b290-11f1-b17e-020000000000","E",61,61,8},{"c970e126-b290-11f1-b421-020000000000","E",69,69,8},{"c970e27a-b290-11f1-9865-020000000000","E",62,62,8},{"c970e3ce-b290-11f1-8451-020000000000","E",65,65,8},{"c970e522-b290-11f1-a8e1-020000000000","E",66,66,8},{"c970e6bc-b290-11f1-b432-020000000000","E",64,64,8},{"c970e806-b290-11f1-81e0-020000000000","E",55,55,8},{"c970e950-b290-11f1-8e1b-020000000000","E",56,56,8},{"c970eaa4-b290-11f1-a99e-020000000000","E",57,57,8},{"c970ec02-b290-11f1-a2ef-020000000000","E",58,58,8},{"c970ed6a-b290-11f1-aa39-020000000000","E",70,70,8},{"c970eeb4-b290-11f1-89aa-020000000000","E",71,71,8},{"c970f01c-b290-11f1-9a9c-020000000000","E",72,72,8},{"c970f184-b290-11f1-b698-020000000000","E",75,75,8},{"c970f2e2-b290-11f1-add7-020000000000","E",76,76,8},{"c970f454-b290-11f1-b9b9-020000000000","E",73,73,8},{"c970f5c6-b290-11f1-a6d6-020000000000","E",74,74,8},{"c970f72e-b290-11f1-9e51-020000000000","E",77,77,8},{"c970f896-b290-11f1-b7bb-020000000000","E",27,27,8},{"c970f9fe-b290-11f1-9752-020000000000","E",26,26,8},{"c970fb66-b290-11f1-a970-020000000000","E",1,1,8},{"c970fc56-b290-11f1-8cbd-020000000000","E",2,2,8},{"c970fdbe-b290-11f1-b007-020000000000","E",3,3,8},{"c970ffb2-b290-11f1-b600-020000000000","E",0,0,8},{"c9710016-b290-11f1-b101-020000000000","E",47,47,8},{"c9710192-b290-11f1-ab3a-020000000000","E",48,48,8},{"c97102e6-b290-11f1-bdbb-020000000000","E",49,49,8},{"c971046c-b290-11f1-a84e-020000000000","E",42,42,8},{"c97105ca-b290-11f1-acba-020000000000","E",43,43,8},{"c9710872-b290-11f1-b465-020000000000","E",44,44,8},{"c971098a-b290-11f1-9e07-020000000000","E",45,45,8},{"c9710af2-b290-11f1-a113-020000000000","E",46,46,8}},
["/mod/2/Level"]={{"c9710de0-b290-11f1-80cf-020000000000","F",-1000,1000,8}},
["/mod/2/Offset"]={{"c9710e80-b290-11f1-8a64-020000000000","F",-1000,1000,8}},
["/mod/3/Source"]={{"c97113c6-b290-11f1-8e47-020000000000","E",1,1,9},{"c9711524-b290-11f1-a25b-020000000000","E",2,2,9},{"c971160a-b290-11f1-92f8-020000000000","E",3,3,9},{"c97116e6-b290-11f1-b8db-020000000000","E",4,4,9},{"c97117cc-b290-11f1-a1b7-020000000000","E",6,6,9},{"c9711920-b290-11f1-ba9c-020000000000","E",7,7,9},{"c9711a74-b290-11f1-a8ef-020000000000","E",16,16,9},{"c9711bd2-b290-11f1-8599-020000000000","E",17,17,9},{"c9711cfe-b290-11f1-9cfd-020000000000","E",18,18,9},{"c9711e5c-b290-11f1-9369-020000000000","E",19,19,9},{"c9711fb0-b290-11f1-9665-020000000000","E",20,20,9},{"c97120fa-b290-11f1-b964-020000000000","E",21,21,9},{"c971223a-b290-11f1-b428-020000000000","E",22,22,9},{"c9712370-b290-11f1-859c-020000000000","E",23,23,9},{"c97124ba-b290-11f1-90d9-020000000000","E",24,24,9},{"c97125fa-b290-11f1-98de-020000000000","E",25,25,9},{"c9712744-b290-11f1-9fb3-020000000000","E",26,26,9},{"c9712898-b290-11f1-b076-020000000000","E",27,27,9},{"c9712a14-b290-11f1-86a8-020000000000","E",28,28,9},{"c9712b68-b290-11f1-bc59-020000000000","E",29,29,9},{"c9712ca8-b290-11f1-b644-020000000000","E",30,30,9},{"c9712e2e-b290-11f1-a4ac-020000000000","E",31,31,9},{"c9712f96-b290-11f1-9abf-020000000000","E",32,32,9},{"c97130f4-b290-11f1-bce9-020000000000","E",34,34,9},{"c9713252-b290-11f1-91ef-020000000000","E",35,35,9},{"c97133a6-b290-11f1-afe9-020000000000","E",36,36,9},{"c9713504-b290-11f1-b04f-020000000000","E",37,37,9},{"c9713644-b290-11f1-ab60-020000000000","E",5,5,9},{"c97137de-b290-11f1-b3ab-020000000000","E",8,8,9},{"c9713928-b290-11f1-816e-020000000000","E",9,9,9},{"c9713aae-b290-11f1-8353-020000000000","E",10,10,9},{"c9713c20-b290-11f1-bcea-020000000000","E",11,11,9},{"c9713d88-b290-11f1-bbf4-020000000000","E",12,12,9},{"c9713efa-b290-11f1-8caf-020000000000","E",13,13,9},{"c9714062-b290-11f1-85d7-020000000000","E",14,14,9},{"c97141d4-b290-11f1-a30d-020000000000","E",15,15,9},{"c9714418-b290-11f1-ac99-020000000000","E",0,0,9}},
["/mod/3/Destination"]={{"c9714490-b290-11f1-8c4c-020000000000","E",25,25,9},{"c9714616-b290-11f1-9d65-020000000000","E",29,29,9},{"c9714788-b290-11f1-a1e5-020000000000","E",30,30,9},{"c97148f0-b290-11f1-9e2f-020000000000","E",10,10,9},{"c9714a4e-b290-11f1-8c64-020000000000","E",6,6,9},{"c9714bc0-b290-11f1-9dc8-020000000000","E",9,9,9},{"c9714d46-b290-11f1-b107-020000000000","E",12,12,9},{"c9714fee-b290-11f1-ba69-020000000000","E",13,13,9},{"c971519c-b290-11f1-a9a2-020000000000","E",14,14,9},{"c97152e6-b290-11f1-b288-020000000000","E",15,15,9},{"c9715444-b290-11f1-8b5c-020000000000","E",21,21,9},{"c971558e-b290-11f1-aa01-020000000000","E",33,33,9},{"c97156f6-b290-11f1-9da8-020000000000","E",34,34,9},{"c9715840-b290-11f1-8939-020000000000","E",31,31,9},{"c971599e-b290-11f1-bd1d-020000000000","E",37,37,9},{"c9715ade-b290-11f1-a6aa-020000000000","E",35,35,9},{"c9715c1e-b290-11f1-a97f-020000000000","E",36,36,9},{"c9715d5e-b290-11f1-af4b-020000000000","E",28,28,9},{"c9715ea8-b290-11f1-b3f2-020000000000","E",5,5,9},{"c9715fe8-b290-11f1-9cf5-020000000000","E",4,4,9},{"c9716128-b290-11f1-a00a-020000000000","E",8,8,9},{"c9716268-b290-11f1-83dd-020000000000","E",7,7,9},{"c97163c6-b290-11f1-abbb-020000000000","E",11,11,9},{"c971651a-b290-11f1-a603-020000000000","E",19,19,9},{"c9716664-b290-11f1-8c53-020000000000","E",20,20,9},{"c97167c2-b290-11f1-93c4-020000000000","E",32,32,9},{"c9716902-b290-11f1-9ad5-020000000000","E",39,39,9},{"c97169ca-b290-11f1-baef-020000000000","E",40,40,9},{"c9716b64-b290-11f1-86d4-020000000000","E",16,16,9},{"c9716cd6-b290-11f1-87bd-020000000000","E",22,22,9},{"c9716e16-b290-11f1-b151-020000000000","E",23,23,9},{"c9716f6a-b290-11f1-bd13-020000000000","E",38,38,9},{"c97170a0-b290-11f1-a1e6-020000000000","E",24,24,9},{"c97171ea-b290-11f1-a576-020000000000","E",17,17,9},{"c9717320-b290-11f1-99d2-020000000000","E",18,18,9},{"c971746a-b290-11f1-9a9b-020000000000","E",41,41,9},{"c97175b4-b290-11f1-ae41-020000000000","E",63,63,9},{"c97176fe-b290-11f1-b048-020000000000","E",67,67,9},{"c9717852-b290-11f1-8c42-020000000000","E",68,68,9},{"c97179b0-b290-11f1-9c2e-020000000000","E",50,50,9},{"c9717afa-b290-11f1-9ac0-020000000000","E",51,51,9},{"c9717c62-b290-11f1-bac1-020000000000","E",52,52,9},{"c9717dc0-b290-11f1-8127-020000000000","E",53,53,9},{"c9717f14-b290-11f1-9ca2-020000000000","E",54,54,9},{"c971805e-b290-11f1-afa4-020000000000","E",59,59,9},{"c97181b2-b290-11f1-b66a-020000000000","E",60,60,9},{"c97182f2-b290-11f1-82cf-020000000000","E",61,61,9},{"c9718478-b290-11f1-9ea5-020000000000","E",69,69,9},{"c97185e0-b290-11f1-aa31-020000000000","E",62,62,9},{"c9718720-b290-11f1-8c5a-020000000000","E",65,65,9},{"c971887e-b290-11f1-b899-020000000000","E",66,66,9},{"c97189e6-b290-11f1-a4df-020000000000","E",64,64,9},{"c9718b3a-b290-11f1-aa55-020000000000","E",55,55,9},{"c9718c98-b290-11f1-bd64-020000000000","E",56,56,9},{"c9718df6-b290-11f1-887a-020000000000","E",57,57,9},{"c9718f4a-b290-11f1-bbb4-020000000000","E",58,58,9},{"c97190d0-b290-11f1-9781-020000000000","E",70,70,9},{"c971922e-b290-11f1-ab30-020000000000","E",71,71,9},{"c9719364-b290-11f1-bb7e-020000000000","E",72,72,9},{"c97194b8-b290-11f1-9f15-020000000000","E",75,75,9},{"c9719602-b290-11f1-9da0-020000000000","E",76,76,9},{"c971974c-b290-11f1-ba0e-020000000000","E",73,73,9},{"c971988c-b290-11f1-a7dd-020000000000","E",74,74,9},{"c97199cc-b290-11f1-ac07-020000000000","E",77,77,9},{"c9719b34-b290-11f1-9c1f-020000000000","E",27,27,9},{"c9719c74-b290-11f1-9ae7-020000000000","E",26,26,9},{"c9719ddc-b290-11f1-b75b-020000000000","E",1,1,9},{"c9719eb8-b290-11f1-8e10-020000000000","E",2,2,9},{"c971a034-b290-11f1-9b71-020000000000","E",3,3,9},{"c971a1f6-b290-11f1-a5ce-020000000000","E",0,0,9},{"c971a250-b290-11f1-9ee9-020000000000","E",47,47,9},{"c971a3a4-b290-11f1-838b-020000000000","E",48,48,9},{"c971a502-b290-11f1-a1c4-020000000000","E",49,49,9},{"c971a656-b290-11f1-b5bc-020000000000","E",42,42,9},{"c971a7a0-b290-11f1-b0ed-020000000000","E",43,43,9},{"c971a8e0-b290-11f1-a505-020000000000","E",44,44,9},{"c971a9d0-b290-11f1-9083-020000000000","E",45,45,9},{"c971ab24-b290-11f1-bf63-020000000000","E",46,46,9}},
["/mod/3/Level"]={{"c971ae08-b290-11f1-90a9-020000000000","F",-1000,1000,9}},
["/mod/3/Offset"]={{"c971ae9e-b290-11f1-9516-020000000000","F",-1000,1000,9}},
["/mod/4/Source"]={{"c971ba92-b290-11f1-8b73-020000000000","E",1,1,10},{"c971bbc8-b290-11f1-a2c7-020000000000","E",2,2,10},{"c971bc9a-b290-11f1-81b8-020000000000","E",3,3,10},{"c971bd58-b290-11f1-b4cb-020000000000","E",4,4,10},{"c971be34-b290-11f1-ac43-020000000000","E",6,6,10},{"c971bf7e-b290-11f1-ac98-020000000000","E",7,7,10},{"c971c0a0-b290-11f1-855e-020000000000","E",16,16,10},{"c971c1d6-b290-11f1-888b-020000000000","E",17,17,10},{"c971c316-b290-11f1-8dcb-020000000000","E",18,18,10},{"c971c44c-b290-11f1-af0a-020000000000","E",19,19,10},{"c971c582-b290-11f1-aa4b-020000000000","E",20,20,10},{"c971c6ae-b290-11f1-a4a5-020000000000","E",21,21,10},{"c971c802-b290-11f1-8682-020000000000","E",22,22,10},{"c971c924-b290-11f1-bdef-020000000000","E",23,23,10},{"c971ca50-b290-11f1-8929-020000000000","E",24,24,10},{"c971cb7c-b290-11f1-96e9-020000000000","E",25,25,10},{"c971cca8-b290-11f1-9bb7-020000000000","E",26,26,10},{"c971cde8-b290-11f1-9323-020000000000","E",27,27,10},{"c971cf14-b290-11f1-8fa4-020000000000","E",28,28,10},{"c971d04a-b290-11f1-afa5-020000000000","E",29,29,10},{"c971d180-b290-11f1-b9fa-020000000000","E",30,30,10},{"c971d2ca-b290-11f1-a5e0-020000000000","E",31,31,10},{"c971d3f6-b290-11f1-bf9e-020000000000","E",32,32,10},{"c971d522-b290-11f1-b28c-020000000000","E",34,34,10},{"c971d662-b290-11f1-be78-020000000000","E",35,35,10},{"c971d78e-b290-11f1-8e69-020000000000","E",36,36,10},{"c971d8d8-b290-11f1-b090-020000000000","E",37,37,10},{"c971d9fa-b290-11f1-88ca-020000000000","E",5,5,10},{"c971db30-b290-11f1-b1e3-020000000000","E",8,8,10},{"c971dc8e-b290-11f1-b59a-020000000000","E",9,9,10},{"c971ddba-b290-11f1-938b-020000000000","E",10,10,10},{"c971defa-b290-11f1-be91-020000000000","E",11,11,10},{"c971e04e-b290-11f1-9863-020000000000","E",12,12,10},{"c971e1a2-b290-11f1-aef1-020000000000","E",13,13,10},{"c971e2d8-b290-11f1-a47a-020000000000","E",14,14,10},{"c971e42c-b290-11f1-851e-020000000000","E",15,15,10},{"c971e65c-b290-11f1-8515-020000000000","E",0,0,10}},
["/mod/4/Destination"]={{"c971e6ca-b290-11f1-a0cd-020000000000","E",25,25,10},{"c971e814-b290-11f1-a3a6-020000000000","E",29,29,10},{"c971e954-b290-11f1-899e-020000000000","E",30,30,10},{"c971eada-b290-11f1-a318-020000000000","E",10,10,10},{"c971ec38-b290-11f1-8c13-020000000000","E",6,6,10},{"c971ed8c-b290-11f1-940b-020000000000","E",9,9,10},{"c971eeea-b290-11f1-8766-020000000000","E",12,12,10},{"c971f052-b290-11f1-95bc-020000000000","E",13,13,10},{"c971f19c-b290-11f1-9cb7-020000000000","E",14,14,10},{"c971f2e6-b290-11f1-808a-020000000000","E",15,15,10},{"c971f426-b290-11f1-ab5d-020000000000","E",21,21,10},{"c971f552-b290-11f1-b92c-020000000000","E",33,33,10},{"c971f688-b290-11f1-96f7-020000000000","E",34,34,10},{"c971f7be-b290-11f1-8423-020000000000","E",31,31,10},{"c971f8ea-b290-11f1-a294-020000000000","E",37,37,10},{"c971fa2a-b290-11f1-846d-020000000000","E",35,35,10},{"c971fb7e-b290-11f1-8174-020000000000","E",36,36,10},{"c971fce6-b290-11f1-998c-020000000000","E",28,28,10},{"c971fe1c-b290-11f1-b5b5-020000000000","E",5,5,10},{"c971ff5c-b290-11f1-beac-020000000000","E",4,4,10},{"c97200a6-b290-11f1-abd8-020000000000","E",8,8,10},{"c97201d2-b290-11f1-97e0-020000000000","E",7,7,10},{"c972031c-b290-11f1-a6c7-020000000000","E",11,11,10},{"c9720470-b290-11f1-9dd3-020000000000","E",19,19,10},{"c97205b0-b290-11f1-83dd-020000000000","E",20,20,10},{"c97206fa-b290-11f1-ab57-020000000000","E",32,32,10},{"c9720826-b290-11f1-a449-020000000000","E",39,39,10},{"c97208f8-b290-11f1-bfaf-020000000000","E",40,40,10},{"c9720aba-b290-11f1-936d-020000000000","E",16,16,10},{"c9720bf0-b290-11f1-8786-020000000000","E",22,22,10},{"c9720d1c-b290-11f1-8a2e-020000000000","E",23,23,10},{"c9720e5c-b290-11f1-a72c-020000000000","E",38,38,10},{"c9720f88-b290-11f1-bdb2-020000000000","E",24,24,10},{"c97210aa-b290-11f1-b57c-020000000000","E",17,17,10},{"c9721208-b290-11f1-aee1-020000000000","E",18,18,10},{"c9721334-b290-11f1-8b06-020000000000","E",41,41,10},{"c9721460-b290-11f1-86e5-020000000000","E",63,63,10},{"c972158c-b290-11f1-a6bf-020000000000","E",67,67,10},{"c97216ae-b290-11f1-ad12-020000000000","E",68,68,10},{"c972180c-b290-11f1-9eb5-020000000000","E",50,50,10},{"c9721942-b290-11f1-9489-020000000000","E",51,51,10},{"c9721a78-b290-11f1-8ebb-020000000000","E",52,52,10},{"c9721bc2-b290-11f1-8fab-020000000000","E",53,53,10},{"c9721cee-b290-11f1-ac2f-020000000000","E",54,54,10},{"c9721e1a-b290-11f1-b873-020000000000","E",59,59,10},{"c9721f5a-b290-11f1-8a65-020000000000","E",60,60,10},{"c972207c-b290-11f1-a22b-020000000000","E",61,61,10},{"c97221bc-b290-11f1-b8c4-020000000000","E",69,69,10},{"c97222fc-b290-11f1-b770-020000000000","E",62,62,10},{"c972243c-b290-11f1-a30e-020000000000","E",65,65,10},{"c972257c-b290-11f1-a1f2-020000000000","E",66,66,10},{"c97226a8-b290-11f1-8d46-020000000000","E",64,64,10},{"c97227de-b290-11f1-b144-020000000000","E",55,55,10},{"c9722914-b290-11f1-879f-020000000000","E",56,56,10},{"c9722a40-b290-11f1-9510-020000000000","E",57,57,10},{"c9722b76-b290-11f1-8ae5-020000000000","E",58,58,10},{"c9722ca2-b290-11f1-97c6-020000000000","E",70,70,10},{"c9722dd8-b290-11f1-9dbf-020000000000","E",71,71,10},{"c9722f0e-b290-11f1-a601-020000000000","E",72,72,10},{"c9723058-b290-11f1-8f86-020000000000","E",75,75,10},{"c9723184-b290-11f1-aefe-020000000000","E",76,76,10},{"c97232b0-b290-11f1-b5b3-020000000000","E",73,73,10},{"c97233f0-b290-11f1-a91c-020000000000","E",74,74,10},{"c972351c-b290-11f1-b14b-020000000000","E",77,77,10},{"c9723648-b290-11f1-a52a-020000000000","E",27,27,10},{"c9723792-b290-11f1-bea7-020000000000","E",26,26,10},{"c97238be-b290-11f1-b559-020000000000","E",1,1,10},{"c972399a-b290-11f1-83bc-020000000000","E",2,2,10},{"c9723ad0-b290-11f1-bea1-020000000000","E",3,3,10},{"c9723c6a-b290-11f1-8fdb-020000000000","E",0,0,10},{"c9723cc4-b290-11f1-a1cc-020000000000","E",47,47,10},{"c9723df0-b290-11f1-8418-020000000000","E",48,48,10},{"c9723f30-b290-11f1-b9ec-020000000000","E",49,49,10},{"c972405c-b290-11f1-9895-020000000000","E",42,42,10},{"c9724192-b290-11f1-9958-020000000000","E",43,43,10},{"c97242be-b290-11f1-abf5-020000000000","E",44,44,10},{"c9724390-b290-11f1-a09a-020000000000","E",45,45,10},{"c97244d0-b290-11f1-b8c9-020000000000","E",46,46,10}},
["/mod/4/Level"]={{"c9724764-b290-11f1-8a98-020000000000","F",-1000,1000,10}},
["/mod/4/Offset"]={{"c97247f0-b290-11f1-a48f-020000000000","F",-1000,1000,10}},
["/mod/5/Source"]={{"c9725254-b290-11f1-8d58-020000000000","E",1,1,11},{"c972538a-b290-11f1-9211-020000000000","E",2,2,11},{"c972545c-b290-11f1-a2b6-020000000000","E",3,3,11},{"c9725524-b290-11f1-b2c5-020000000000","E",4,4,11},{"c97255ec-b290-11f1-a8cc-020000000000","E",6,6,11},{"c9725722-b290-11f1-b924-020000000000","E",7,7,11},{"c972584e-b290-11f1-a0d9-020000000000","E",16,16,11},{"c97259a2-b290-11f1-83ee-020000000000","E",17,17,11},{"c9725ad8-b290-11f1-852c-020000000000","E",18,18,11},{"c9725c0e-b290-11f1-9460-020000000000","E",19,19,11},{"c9725d4e-b290-11f1-bbe5-020000000000","E",20,20,11},{"c9725e8e-b290-11f1-93fe-020000000000","E",21,21,11},{"c9725fb0-b290-11f1-8c8c-020000000000","E",22,22,11},{"c97260e6-b290-11f1-9518-020000000000","E",23,23,11},{"c9726212-b290-11f1-a289-020000000000","E",24,24,11},{"c972635c-b290-11f1-b4bf-020000000000","E",25,25,11},{"c972649c-b290-11f1-936e-020000000000","E",26,26,11},{"c97265dc-b290-11f1-b90d-020000000000","E",27,27,11},{"c9726708-b290-11f1-a6e3-020000000000","E",28,28,11},{"c972682a-b290-11f1-a59e-020000000000","E",29,29,11},{"c9726960-b290-11f1-82fb-020000000000","E",30,30,11},{"c9726aa0-b290-11f1-9665-020000000000","E",31,31,11},{"c9726bf4-b290-11f1-baec-020000000000","E",32,32,11},{"c9726d34-b290-11f1-9b7a-020000000000","E",34,34,11},{"c9726e9c-b290-11f1-a5ca-020000000000","E",35,35,11},{"c9726fd2-b290-11f1-b2c3-020000000000","E",36,36,11},{"c9727112-b290-11f1-a60e-020000000000","E",37,37,11},{"c9727266-b290-11f1-ae37-020000000000","E",5,5,11},{"c97273a6-b290-11f1-9a90-020000000000","E",8,8,11},{"c97274d2-b290-11f1-9879-020000000000","E",9,9,11},{"c9727608-b290-11f1-8b0b-020000000000","E",10,10,11},{"c972773e-b290-11f1-85a9-020000000000","E",11,11,11},{"c972787e-b290-11f1-b4e7-020000000000","E",12,12,11},{"c97279a0-b290-11f1-bb16-020000000000","E",13,13,11},{"c9727ad6-b290-11f1-8d4e-020000000000","E",14,14,11},{"c9727c02-b290-11f1-b2e1-020000000000","E",15,15,11},{"c9727e82-b290-11f1-8348-020000000000","E",0,0,11}},
["/mod/5/Destination"]={{"c9727edc-b290-11f1-88bb-020000000000","E",25,25,11},{"c9728044-b290-11f1-bf32-020000000000","E",29,29,11},{"c9728184-b290-11f1-ab59-020000000000","E",30,30,11},{"c97282ce-b290-11f1-860a-020000000000","E",10,10,11},{"c972840e-b290-11f1-8290-020000000000","E",6,6,11},{"c9728576-b290-11f1-b155-020000000000","E",9,9,11},{"c97286ca-b290-11f1-8686-020000000000","E",12,12,11},{"c972880a-b290-11f1-a5dd-020000000000","E",13,13,11},{"c9728954-b290-11f1-8162-020000000000","E",14,14,11},{"c9728a94-b290-11f1-81bd-020000000000","E",15,15,11},{"c9728bde-b290-11f1-95b4-020000000000","E",21,21,11},{"c9728d3c-b290-11f1-a474-020000000000","E",33,33,11},{"c9728e90-b290-11f1-ae12-020000000000","E",34,34,11},{"c9728fe4-b290-11f1-9013-020000000000","E",31,31,11},{"c972911a-b290-11f1-8a8d-020000000000","E",37,37,11},{"c9729282-b290-11f1-8780-020000000000","E",35,35,11},{"c97293c2-b290-11f1-b817-020000000000","E",36,36,11},{"c9729502-b290-11f1-8672-020000000000","E",28,28,11},{"c972967e-b290-11f1-845d-020000000000","E",5,5,11},{"c97297c8-b290-11f1-8191-020000000000","E",4,4,11},{"c9729930-b290-11f1-a743-020000000000","E",8,8,11},{"c9729a8e-b290-11f1-a321-020000000000","E",7,7,11},{"c9729bec-b290-11f1-bc59-020000000000","E",11,11,11},{"c9729d2c-b290-11f1-b3d2-020000000000","E",19,19,11},{"c9729e62-b290-11f1-a489-020000000000","E",20,20,11},{"c9729fb6-b290-11f1-a5c0-020000000000","E",32,32,11},{"c972a0f6-b290-11f1-a597-020000000000","E",39,39,11},{"c972a1b4-b290-11f1-9e56-020000000000","E",40,40,11},{"c972a376-b290-11f1-8611-020000000000","E",16,16,11},{"c972a4ac-b290-11f1-b34f-020000000000","E",22,22,11},{"c972a5e2-b290-11f1-be82-020000000000","E",23,23,11},{"c972a736-b290-11f1-9794-020000000000","E",38,38,11},{"c972a894-b290-11f1-b066-020000000000","E",24,24,11},{"c972a9e8-b290-11f1-af36-020000000000","E",17,17,11},{"c972ab50-b290-11f1-9a80-020000000000","E",18,18,11},{"c972aca4-b290-11f1-bd94-020000000000","E",41,41,11},{"c972ae0c-b290-11f1-b362-020000000000","E",63,63,11},{"c972afba-b290-11f1-b133-020000000000","E",67,67,11},{"c972b136-b290-11f1-bffe-020000000000","E",68,68,11},{"c972b2e4-b290-11f1-8ef9-020000000000","E",50,50,11},{"c972b456-b290-11f1-acd7-020000000000","E",51,51,11},{"c972b5be-b290-11f1-bab1-020000000000","E",52,52,11},{"c972b726-b290-11f1-8f55-020000000000","E",53,53,11},{"c972b898-b290-11f1-bc74-020000000000","E",54,54,11},{"c972ba00-b290-11f1-87b7-020000000000","E",59,59,11},{"c972bb68-b290-11f1-8118-020000000000","E",60,60,11},{"c972bcee-b290-11f1-ac67-020000000000","E",61,61,11},{"c972be4c-b290-11f1-a80e-020000000000","E",69,69,11},{"c972bfa0-b290-11f1-afc0-020000000000","E",62,62,11},{"c972c108-b290-11f1-8ad1-020000000000","E",65,65,11},{"c972c28e-b290-11f1-b927-020000000000","E",66,66,11},{"c972c40a-b290-11f1-b319-020000000000","E",64,64,11},{"c972c568-b290-11f1-b9b5-020000000000","E",55,55,11},{"c972c6f8-b290-11f1-b0b4-020000000000","E",56,56,11},{"c972c838-b290-11f1-8c8a-020000000000","E",57,57,11},{"c972c98c-b290-11f1-a20e-020000000000","E",58,58,11},{"c972caea-b290-11f1-b3e8-020000000000","E",70,70,11},{"c972cc52-b290-11f1-a514-020000000000","E",71,71,11},{"c972cdce-b290-11f1-ab31-020000000000","E",72,72,11},{"c972cf5e-b290-11f1-bc8f-020000000000","E",75,75,11},{"c972d116-b290-11f1-94cc-020000000000","E",76,76,11},{"c972d26a-b290-11f1-9098-020000000000","E",73,73,11},{"c972d3c8-b290-11f1-b207-020000000000","E",74,74,11},{"c972d526-b290-11f1-bf5e-020000000000","E",77,77,11},{"c972d684-b290-11f1-bedf-020000000000","E",27,27,11},{"c972d7d8-b290-11f1-a5e8-020000000000","E",26,26,11},{"c972d940-b290-11f1-81a0-020000000000","E",1,1,11},{"c972da1c-b290-11f1-abbf-020000000000","E",2,2,11},{"c972db84-b290-11f1-a8d4-020000000000","E",3,3,11},{"c972dd50-b290-11f1-b816-020000000000","E",0,0,11},{"c972ddb4-b290-11f1-9ca2-020000000000","E",47,47,11},{"c972df26-b290-11f1-801e-020000000000","E",48,48,11},{"c972e084-b290-11f1-b6ee-020000000000","E",49,49,11},{"c972e1c4-b290-11f1-bee1-020000000000","E",42,42,11},{"c972e304-b290-11f1-8f15-020000000000","E",43,43,11},{"c972e46c-b290-11f1-9c48-020000000000","E",44,44,11},{"c972e53e-b290-11f1-8627-020000000000","E",45,45,11},{"c972e688-b290-11f1-ace3-020000000000","E",46,46,11}},
["/mod/5/Level"]={{"c972e944-b290-11f1-b700-020000000000","F",-1000,1000,11}},
["/mod/5/Offset"]={{"c972e9bc-b290-11f1-b7e1-020000000000","F",-1000,1000,11}},
["/mod/6/Source"]={{"c972f524-b290-11f1-ae66-020000000000","E",1,1,12},{"c972f678-b290-11f1-9487-020000000000","E",2,2,12},{"c972f75e-b290-11f1-a55f-020000000000","E",3,3,12},{"c972f83a-b290-11f1-a3e4-020000000000","E",4,4,12},{"c972f902-b290-11f1-9d9a-020000000000","E",6,6,12},{"c972fa4c-b290-11f1-9b77-020000000000","E",7,7,12},{"c972fbd2-b290-11f1-85af-020000000000","E",16,16,12},{"c972fd30-b290-11f1-8ae2-020000000000","E",17,17,12},{"c972fe84-b290-11f1-8bf5-020000000000","E",18,18,12},{"c972ffd8-b290-11f1-8691-020000000000","E",19,19,12},{"c9730140-b290-11f1-a520-020000000000","E",20,20,12},{"c9730280-b290-11f1-812c-020000000000","E",21,21,12},{"c97303f2-b290-11f1-bc2c-020000000000","E",22,22,12},{"c9730546-b290-11f1-ad4b-020000000000","E",23,23,12},{"c97306a4-b290-11f1-9672-020000000000","E",24,24,12},{"c9730816-b290-11f1-9d42-020000000000","E",25,25,12},{"c9730974-b290-11f1-b335-020000000000","E",26,26,12},{"c9730ab4-b290-11f1-90ee-020000000000","E",27,27,12},{"c9730c12-b290-11f1-9fa1-020000000000","E",28,28,12},{"c9730dc0-b290-11f1-bfb4-020000000000","E",29,29,12},{"c9730f0a-b290-11f1-a61d-020000000000","E",30,30,12},{"c9731054-b290-11f1-85f8-020000000000","E",31,31,12},{"c97311ee-b290-11f1-a72a-020000000000","E",32,32,12},{"c9731360-b290-11f1-a0f8-020000000000","E",34,34,12},{"c97314dc-b290-11f1-bd7e-020000000000","E",35,35,12},{"c9731662-b290-11f1-8bb5-020000000000","E",36,36,12},{"c9731842-b290-11f1-a599-020000000000","E",37,37,12},{"c97319c8-b290-11f1-bcde-020000000000","E",5,5,12},{"c9731b12-b290-11f1-9953-020000000000","E",8,8,12},{"c9731c7a-b290-11f1-9471-020000000000","E",9,9,12},{"c9731de2-b290-11f1-91b1-020000000000","E",10,10,12},{"c9731f4a-b290-11f1-b183-020000000000","E",11,11,12},{"c97320c6-b290-11f1-af1e-020000000000","E",12,12,12},{"c9732260-b290-11f1-bf06-020000000000","E",13,13,12},{"c97323d2-b290-11f1-ab8d-020000000000","E",14,14,12},{"c973254e-b290-11f1-aef8-020000000000","E",15,15,12},{"c97328a0-b290-11f1-a54d-020000000000","E",0,0,12}},
["/mod/6/Destination"]={{"c9732904-b290-11f1-acf0-020000000000","E",25,25,12},{"c9732a6c-b290-11f1-9837-020000000000","E",29,29,12},{"c9732bfc-b290-11f1-9b04-020000000000","E",30,30,12},{"c9732d5a-b290-11f1-9df7-020000000000","E",10,10,12},{"c9732eb8-b290-11f1-92a1-020000000000","E",6,6,12},{"c9732ff8-b290-11f1-aed7-020000000000","E",9,9,12},{"c973316a-b290-11f1-8851-020000000000","E",12,12,12},{"c97332b4-b290-11f1-9052-020000000000","E",13,13,12},{"c9733408-b290-11f1-af2c-020000000000","E",14,14,12},{"c973355c-b290-11f1-8fbd-020000000000","E",15,15,12},{"c9733692-b290-11f1-9d2b-020000000000","E",21,21,12},{"c97337dc-b290-11f1-93e5-020000000000","E",33,33,12},{"c973391c-b290-11f1-96cf-020000000000","E",34,34,12},{"c9733a70-b290-11f1-9304-020000000000","E",31,31,12},{"c9733bba-b290-11f1-972f-020000000000","E",37,37,12},{"c9733d18-b290-11f1-8800-020000000000","E",35,35,12},{"c9733e62-b290-11f1-98a2-020000000000","E",36,36,12},{"c9733f8e-b290-11f1-85e6-020000000000","E",28,28,12},{"c97340ce-b290-11f1-a8c8-020000000000","E",5,5,12},{"c973420e-b290-11f1-ad92-020000000000","E",4,4,12},{"c973436c-b290-11f1-9dec-020000000000","E",8,8,12},{"c97344ac-b290-11f1-a242-020000000000","E",7,7,12},{"c9734614-b290-11f1-a90e-020000000000","E",11,11,12},{"c97347a4-b290-11f1-9ba2-020000000000","E",19,19,12},{"c97348da-b290-11f1-9c70-020000000000","E",20,20,12},{"c9734a1a-b290-11f1-a48f-020000000000","E",32,32,12},{"c9734b5a-b290-11f1-8a91-020000000000","E",39,39,12},{"c9734c2c-b290-11f1-80f4-020000000000","E",40,40,12},{"c9734dda-b290-11f1-a414-020000000000","E",16,16,12},{"c9734efc-b290-11f1-b154-020000000000","E",22,22,12},{"c973503c-b290-11f1-8755-020000000000","E",23,23,12},{"c9735190-b290-11f1-bdd9-020000000000","E",38,38,12},{"c97352da-b290-11f1-b753-020000000000","E",24,24,12},{"c973541a-b290-11f1-ac24-020000000000","E",17,17,12},{"c9735550-b290-11f1-9232-020000000000","E",18,18,12},{"c9735690-b290-11f1-b75d-020000000000","E",41,41,12},{"c97357bc-b290-11f1-b803-020000000000","E",63,63,12},{"c97358f2-b290-11f1-aba7-020000000000","E",67,67,12},{"c9735a28-b290-11f1-a78e-020000000000","E",68,68,12},{"c9735b54-b290-11f1-8436-020000000000","E",50,50,12},{"c9735c94-b290-11f1-a35d-020000000000","E",51,51,12},{"c9735dca-b290-11f1-b22e-020000000000","E",52,52,12},{"c9735ef6-b290-11f1-99c8-020000000000","E",53,53,12},{"c9736022-b290-11f1-84c4-020000000000","E",54,54,12},{"c973616c-b290-11f1-a60a-020000000000","E",59,59,12},{"c9736298-b290-11f1-8e27-020000000000","E",60,60,12},{"c97363ba-b290-11f1-88c5-020000000000","E",61,61,12},{"c97364f0-b290-11f1-8c38-020000000000","E",69,69,12},{"c973664e-b290-11f1-889f-020000000000","E",62,62,12},{"c9736784-b290-11f1-9e7d-020000000000","E",65,65,12},{"c97368b0-b290-11f1-8659-020000000000","E",66,66,12},{"c97369f0-b290-11f1-93e2-020000000000","E",64,64,12},{"c9736b1c-b290-11f1-939e-020000000000","E",55,55,12},{"c9736c48-b290-11f1-8094-020000000000","E",56,56,12},{"c9736d7e-b290-11f1-9bb8-020000000000","E",57,57,12},{"c9736eb4-b290-11f1-b889-020000000000","E",58,58,12},{"c9736ffe-b290-11f1-806d-020000000000","E",70,70,12},{"c973712a-b290-11f1-8362-020000000000","E",71,71,12},{"c9737260-b290-11f1-b004-020000000000","E",72,72,12},{"c97373a0-b290-11f1-8060-020000000000","E",75,75,12},{"c97374d6-b290-11f1-8bbb-020000000000","E",76,76,12},{"c9737602-b290-11f1-aa67-020000000000","E",73,73,12},{"c973772e-b290-11f1-bf47-020000000000","E",74,74,12},{"c9737878-b290-11f1-92c8-020000000000","E",77,77,12},{"c97379a4-b290-11f1-be1f-020000000000","E",27,27,12},{"c9737b0c-b290-11f1-b85b-020000000000","E",26,26,12},{"c9737c56-b290-11f1-ab78-020000000000","E",1,1,12},{"c9737d1e-b290-11f1-a1f6-020000000000","E",2,2,12},{"c9737e5e-b290-11f1-924f-020000000000","E",3,3,12},{"c9738016-b290-11f1-a4e7-020000000000","E",0,0,12},{"c9738070-b290-11f1-8b8d-020000000000","E",47,47,12},{"c973819c-b290-11f1-b750-020000000000","E",48,48,12},{"c97382d2-b290-11f1-a7a3-020000000000","E",49,49,12},{"c9738408-b290-11f1-bd2a-020000000000","E",42,42,12},{"c973853e-b290-11f1-8c61-020000000000","E",43,43,12},{"c973866a-b290-11f1-b075-020000000000","E",44,44,12},{"c973873c-b290-11f1-bbc1-020000000000","E",45,45,12},{"c9738868-b290-11f1-81cb-020000000000","E",46,46,12}},
["/mod/6/Level"]={{"c9738ade-b290-11f1-9e47-020000000000","F",-1000,1000,12}},
["/mod/6/Offset"]={{"c9738b56-b290-11f1-8f9f-020000000000","F",-1000,1000,12}},
["/mod/7/Source"]={{"c973960a-b290-11f1-909a-020000000000","E",1,1,13},{"c9739754-b290-11f1-84fb-020000000000","E",2,2,13},{"c9739812-b290-11f1-a4b2-020000000000","E",3,3,13},{"c97398da-b290-11f1-a016-020000000000","E",4,4,13},{"c97399ac-b290-11f1-90ee-020000000000","E",6,6,13},{"c9739aec-b290-11f1-af0a-020000000000","E",7,7,13},{"c9739c18-b290-11f1-a503-020000000000","E",16,16,13},{"c9739d3a-b290-11f1-bb58-020000000000","E",17,17,13},{"c9739e70-b290-11f1-9f40-020000000000","E",18,18,13},{"c9739fa6-b290-11f1-95e9-020000000000","E",19,19,13},{"c973a0e6-b290-11f1-8e22-020000000000","E",20,20,13},{"c973a21c-b290-11f1-9a61-020000000000","E",21,21,13},{"c973a352-b290-11f1-8858-020000000000","E",22,22,13},{"c973a4a6-b290-11f1-9aea-020000000000","E",23,23,13},{"c973a5dc-b290-11f1-a39b-020000000000","E",24,24,13},{"c973a712-b290-11f1-8b37-020000000000","E",25,25,13},{"c973a852-b290-11f1-aeb8-020000000000","E",26,26,13},{"c973a988-b290-11f1-8ad8-020000000000","E",27,27,13},{"c973aabe-b290-11f1-b232-020000000000","E",28,28,13},{"c973abe0-b290-11f1-b965-020000000000","E",29,29,13},{"c973ad2a-b290-11f1-957b-020000000000","E",30,30,13},{"c973ae60-b290-11f1-99ec-020000000000","E",31,31,13},{"c973afb4-b290-11f1-88b3-020000000000","E",32,32,13},{"c973b0ea-b290-11f1-a365-020000000000","E",34,34,13},{"c973b22a-b290-11f1-9a41-020000000000","E",35,35,13},{"c973b356-b290-11f1-bdad-020000000000","E",36,36,13},{"c973b48c-b290-11f1-a4b6-020000000000","E",37,37,13},{"c973b5cc-b290-11f1-84e2-020000000000","E",5,5,13},{"c973b720-b290-11f1-8538-020000000000","E",8,8,13},{"c973b86a-b290-11f1-9ea1-020000000000","E",9,9,13},{"c973b9aa-b290-11f1-804f-020000000000","E",10,10,13},{"c973baf4-b290-11f1-a8a8-020000000000","E",11,11,13},{"c973bc2a-b290-11f1-a042-020000000000","E",12,12,13},{"c973bd60-b290-11f1-ac73-020000000000","E",13,13,13},{"c973be96-b290-11f1-a123-020000000000","E",14,14,13},{"c973bfd6-b290-11f1-b483-020000000000","E",15,15,13},{"c973c260-b290-11f1-89a2-020000000000","E",0,0,13}},
["/mod/7/Destination"]={{"c973c2ba-b290-11f1-b8cd-020000000000","E",25,25,13},{"c973c40e-b290-11f1-aa97-020000000000","E",29,29,13},{"c973c544-b290-11f1-ba04-020000000000","E",30,30,13},{"c973c67a-b290-11f1-a7b1-020000000000","E",10,10,13},{"c973c7d8-b290-11f1-85c9-020000000000","E",6,6,13},{"c973c90e-b290-11f1-9b78-020000000000","E",9,9,13},{"c973ca44-b290-11f1-a12b-020000000000","E",12,12,13},{"c973cbc0-b290-11f1-891c-020000000000","E",13,13,13},{"c973cd00-b290-11f1-a88a-020000000000","E",14,14,13},{"c973ce72-b290-11f1-be7f-020000000000","E",15,15,13},{"c973cfa8-b290-11f1-b832-020000000000","E",21,21,13},{"c973d0fc-b290-11f1-be29-020000000000","E",33,33,13},{"c973d246-b290-11f1-b576-020000000000","E",34,34,13},{"c973d39a-b290-11f1-8e84-020000000000","E",31,31,13},{"c973d4da-b290-11f1-9bd5-020000000000","E",37,37,13},{"c973d624-b290-11f1-8644-020000000000","E",35,35,13},{"c973d75a-b290-11f1-89f5-020000000000","E",36,36,13},{"c973d8c2-b290-11f1-b9fb-020000000000","E",28,28,13},{"c973da20-b290-11f1-aced-020000000000","E",5,5,13},{"c973db6a-b290-11f1-9a17-020000000000","E",4,4,13},{"c973dcaa-b290-11f1-83c5-020000000000","E",8,8,13},{"c973de12-b290-11f1-a120-020000000000","E",7,7,13},{"c973df52-b290-11f1-b674-020000000000","E",11,11,13},{"c973e0ba-b290-11f1-af70-020000000000","E",19,19,13},{"c973e1fa-b290-11f1-801f-020000000000","E",20,20,13},{"c973e358-b290-11f1-83f9-020000000000","E",32,32,13},{"c973e4b6-b290-11f1-bcc2-020000000000","E",39,39,13},{"c973e57e-b290-11f1-ac99-020000000000","E",40,40,13},{"c973e736-b290-11f1-b972-020000000000","E",16,16,13},{"c973e86c-b290-11f1-a420-020000000000","E",22,22,13},{"c973e9a2-b290-11f1-8adf-020000000000","E",23,23,13},{"c973eb14-b290-11f1-9021-020000000000","E",38,38,13},{"c973ec9a-b290-11f1-834e-020000000000","E",24,24,13},{"c973edee-b290-11f1-8e0f-020000000000","E",17,17,13},{"c973ef42-b290-11f1-a4e4-020000000000","E",18,18,13},{"c973f096-b290-11f1-b2e1-020000000000","E",41,41,13},{"c973f1d6-b290-11f1-8e85-020000000000","E",63,63,13},{"c973f320-b290-11f1-9107-020000000000","E",67,67,13},{"c973f474-b290-11f1-9397-020000000000","E",68,68,13},{"c973f5c8-b290-11f1-a212-020000000000","E",50,50,13},{"c973f71c-b290-11f1-ac57-020000000000","E",51,51,13},{"c973f85c-b290-11f1-bc61-020000000000","E",52,52,13},{"c973f99c-b290-11f1-a485-020000000000","E",53,53,13},{"c973fae6-b290-11f1-b7ea-020000000000","E",54,54,13},{"c973fc12-b290-11f1-999d-020000000000","E",59,59,13},{"c973fd5c-b290-11f1-b967-020000000000","E",60,60,13},{"c973fe9c-b290-11f1-8ffb-020000000000","E",61,61,13},{"c973fff0-b290-11f1-93b4-020000000000","E",69,69,13},{"c974013a-b290-11f1-9e67-020000000000","E",62,62,13},{"c9740298-b290-11f1-9589-020000000000","E",65,65,13},{"c97403f6-b290-11f1-82a3-020000000000","E",66,66,13},{"c9740554-b290-11f1-934d-020000000000","E",64,64,13},{"c9740694-b290-11f1-ba68-020000000000","E",55,55,13},{"c97407d4-b290-11f1-ab0e-020000000000","E",56,56,13},{"c974090a-b290-11f1-9d0f-020000000000","E",57,57,13},{"c9740a40-b290-11f1-9b3c-020000000000","E",58,58,13},{"c9740b80-b290-11f1-82f9-020000000000","E",70,70,13},{"c9740cc0-b290-11f1-82fc-020000000000","E",71,71,13},{"c9740df6-b290-11f1-b5c1-020000000000","E",72,72,13},{"c9740f40-b290-11f1-a20c-020000000000","E",75,75,13},{"c974106c-b290-11f1-8d11-020000000000","E",76,76,13},{"c97411ac-b290-11f1-ab91-020000000000","E",73,73,13},{"c97412e2-b290-11f1-95f2-020000000000","E",74,74,13},{"c9741436-b290-11f1-98ee-020000000000","E",77,77,13},{"c9741576-b290-11f1-87e7-020000000000","E",27,27,13},{"c97416ac-b290-11f1-8074-020000000000","E",26,26,13},{"c97417d8-b290-11f1-93fe-020000000000","E",1,1,13},{"c97418a0-b290-11f1-add1-020000000000","E",2,2,13},{"c97419e0-b290-11f1-8a64-020000000000","E",3,3,13},{"c9741b98-b290-11f1-b12a-020000000000","E",0,0,13},{"c9741bf2-b290-11f1-9cec-020000000000","E",47,47,13},{"c9741d64-b290-11f1-b17b-020000000000","E",48,48,13},{"c9741eae-b290-11f1-8eae-020000000000","E",49,49,13},{"c9741fe4-b290-11f1-bcc2-020000000000","E",42,42,13},{"c9742110-b290-11f1-840e-020000000000","E",43,43,13},{"c9742264-b290-11f1-8d43-020000000000","E",44,44,13},{"c9742322-b290-11f1-b953-020000000000","E",45,45,13},{"c9742476-b290-11f1-aadd-020000000000","E",46,46,13}},
["/mod/7/Level"]={{"c97426f6-b290-11f1-9aa6-020000000000","F",-1000,1000,13}},
["/mod/7/Offset"]={{"c974276e-b290-11f1-b84e-020000000000","F",-1000,1000,13}},
["/mod/8/Source"]={{"c974325e-b290-11f1-9705-020000000000","E",1,1,14},{"c974338a-b290-11f1-a6e8-020000000000","E",2,2,14},{"c974345c-b290-11f1-b689-020000000000","E",3,3,14},{"c9743524-b290-11f1-a7c9-020000000000","E",4,4,14},{"c97435ec-b290-11f1-9046-020000000000","E",6,6,14},{"c9743718-b290-11f1-9655-020000000000","E",7,7,14},{"c9743844-b290-11f1-bad5-020000000000","E",16,16,14},{"c974398e-b290-11f1-8ef0-020000000000","E",17,17,14},{"c9743ae2-b290-11f1-9f25-020000000000","E",18,18,14},{"c9743c0e-b290-11f1-a466-020000000000","E",19,19,14},{"c9743d3a-b290-11f1-ab1f-020000000000","E",20,20,14},{"c9743e70-b290-11f1-8df9-020000000000","E",21,21,14},{"c9743fa6-b290-11f1-a1c3-020000000000","E",22,22,14},{"c97440d2-b290-11f1-b0ac-020000000000","E",23,23,14},{"c9744208-b290-11f1-862e-020000000000","E",24,24,14},{"c974433e-b290-11f1-ae50-020000000000","E",25,25,14},{"c9744474-b290-11f1-8434-020000000000","E",26,26,14},{"c97445aa-b290-11f1-b13d-020000000000","E",27,27,14},{"c97446ea-b290-11f1-9457-020000000000","E",28,28,14},{"c9744820-b290-11f1-b9c1-020000000000","E",29,29,14},{"c9744956-b290-11f1-b96e-020000000000","E",30,30,14},{"c9744a82-b290-11f1-b2da-020000000000","E",31,31,14},{"c9744bb8-b290-11f1-902c-020000000000","E",32,32,14},{"c9744cf8-b290-11f1-8254-020000000000","E",34,34,14},{"c9744e2e-b290-11f1-b5ed-020000000000","E",35,35,14},{"c9744f6e-b290-11f1-a02b-020000000000","E",36,36,14},{"c97450a4-b290-11f1-ae13-020000000000","E",37,37,14},{"c97451d0-b290-11f1-8872-020000000000","E",5,5,14},{"c97452fc-b290-11f1-8001-020000000000","E",8,8,14},{"c9745432-b290-11f1-b181-020000000000","E",9,9,14},{"c9745568-b290-11f1-b4c2-020000000000","E",10,10,14},{"c9745694-b290-11f1-9c99-020000000000","E",11,11,14},{"c97457d4-b290-11f1-b79c-020000000000","E",12,12,14},{"c9745928-b290-11f1-b789-020000000000","E",13,13,14},{"c9745a4a-b290-11f1-a793-020000000000","E",14,14,14},{"c9745b80-b290-11f1-ad28-020000000000","E",15,15,14},{"c9745e82-b290-11f1-bbb3-020000000000","E",0,0,14}},
["/mod/8/Destination"]={{"c9745efa-b290-11f1-ade6-020000000000","E",25,25,14},{"c9746080-b290-11f1-ae98-020000000000","E",29,29,14},{"c97461fc-b290-11f1-8c93-020000000000","E",30,30,14},{"c9746378-b290-11f1-aadb-020000000000","E",10,10,14},{"c97464f4-b290-11f1-a5af-020000000000","E",6,6,14},{"c9746684-b290-11f1-bae7-020000000000","E",9,9,14},{"c974680a-b290-11f1-8cbc-020000000000","E",12,12,14},{"c9746986-b290-11f1-b58a-020000000000","E",13,13,14},{"c9746af8-b290-11f1-8ac5-020000000000","E",14,14,14},{"c9746c92-b290-11f1-ad68-020000000000","E",15,15,14},{"c9746e0e-b290-11f1-9491-020000000000","E",21,21,14},{"c9746f80-b290-11f1-9f63-020000000000","E",33,33,14},{"c974712e-b290-11f1-ae18-020000000000","E",34,34,14},{"c9747296-b290-11f1-bf60-020000000000","E",31,31,14},{"c9747408-b290-11f1-a1b7-020000000000","E",37,37,14},{"c9747584-b290-11f1-84c7-020000000000","E",35,35,14},{"c974770a-b290-11f1-84e7-020000000000","E",36,36,14},{"c9747890-b290-11f1-8f6f-020000000000","E",28,28,14},{"c9747a16-b290-11f1-a95c-020000000000","E",5,5,14},{"c9747bba-b290-11f1-a924-020000000000","E",4,4,14},{"c9747d36-b290-11f1-913c-020000000000","E",8,8,14},{"c9747ebc-b290-11f1-b255-020000000000","E",7,7,14},{"c9748038-b290-11f1-8458-020000000000","E",11,11,14},{"c97481aa-b290-11f1-af7f-020000000000","E",19,19,14},{"c9748330-b290-11f1-8431-020000000000","E",20,20,14},{"c97484b6-b290-11f1-9298-020000000000","E",32,32,14},{"c9748632-b290-11f1-8b49-020000000000","E",39,39,14},{"c9748736-b290-11f1-8392-020000000000","E",40,40,14},{"c9748920-b290-11f1-987e-020000000000","E",16,16,14},{"c9748ab0-b290-11f1-8774-020000000000","E",22,22,14},{"c9748c2c-b290-11f1-8a5d-020000000000","E",23,23,14},{"c9748dbc-b290-11f1-974f-020000000000","E",38,38,14},{"c9748f2e-b290-11f1-8382-020000000000","E",24,24,14},{"c97490be-b290-11f1-9287-020000000000","E",17,17,14},{"c974923a-b290-11f1-8452-020000000000","E",18,18,14},{"c97493c0-b290-11f1-ba47-020000000000","E",41,41,14},{"c974953c-b290-11f1-820b-020000000000","E",63,63,14},{"c97496d6-b290-11f1-9b64-020000000000","E",67,67,14},{"c9749848-b290-11f1-97ba-020000000000","E",68,68,14},{"c97499b0-b290-11f1-b557-020000000000","E",50,50,14},{"c9749b22-b290-11f1-ac51-020000000000","E",51,51,14},{"c9749ca8-b290-11f1-93a9-020000000000","E",52,52,14},{"c9749e4c-b290-11f1-9328-020000000000","E",53,53,14},{"c9749ff0-b290-11f1-98ab-020000000000","E",54,54,14},{"c974a162-b290-11f1-b48c-020000000000","E",59,59,14},{"c974a2d4-b290-11f1-b99f-020000000000","E",60,60,14},{"c974a450-b290-11f1-94f6-020000000000","E",61,61,14},{"c974a5cc-b290-11f1-a8b2-020000000000","E",69,69,14},{"c974a748-b290-11f1-bbec-020000000000","E",62,62,14},{"c974a8ce-b290-11f1-afd5-020000000000","E",65,65,14},{"c974aa4a-b290-11f1-8397-020000000000","E",66,66,14},{"c974abda-b290-11f1-8d07-020000000000","E",64,64,14},{"c974ad56-b290-11f1-b699-020000000000","E",55,55,14},{"c974aec8-b290-11f1-97b8-020000000000","E",56,56,14},{"c974b06c-b290-11f1-a2a6-020000000000","E",57,57,14},{"c974b1f2-b290-11f1-bee6-020000000000","E",58,58,14},{"c974b35a-b290-11f1-a5cd-020000000000","E",70,70,14},{"c974b4d6-b290-11f1-b294-020000000000","E",71,71,14},{"c974b652-b290-11f1-94ec-020000000000","E",72,72,14},{"c974b7ba-b290-11f1-ab05-020000000000","E",75,75,14},{"c974b936-b290-11f1-8a67-020000000000","E",76,76,14},{"c974babc-b290-11f1-bf93-020000000000","E",73,73,14},{"c974bc4c-b290-11f1-b24b-020000000000","E",74,74,14},{"c974bdb4-b290-11f1-82ac-020000000000","E",77,77,14},{"c974bf26-b290-11f1-ae3e-020000000000","E",27,27,14},{"c974c0a2-b290-11f1-89fa-020000000000","E",26,26,14},{"c974c21e-b290-11f1-951d-020000000000","E",1,1,14},{"c974c32c-b290-11f1-acf0-020000000000","E",2,2,14},{"c974c49e-b290-11f1-ac56-020000000000","E",3,3,14},{"c974c69c-b290-11f1-a49c-020000000000","E",0,0,14},{"c974c70a-b290-11f1-98ff-020000000000","E",47,47,14},{"c974c890-b290-11f1-9fa1-020000000000","E",48,48,14},{"c974ca02-b290-11f1-8512-020000000000","E",49,49,14},{"c974cb74-b290-11f1-b14f-020000000000","E",42,42,14},{"c974cd04-b290-11f1-b74b-020000000000","E",43,43,14},{"c974ce6c-b290-11f1-8eea-020000000000","E",44,44,14},{"c974cf5c-b290-11f1-81af-020000000000","E",45,45,14},{"c974d0d8-b290-11f1-b0cc-020000000000","E",46,46,14}},
["/mod/8/Level"]={{"c974d3da-b290-11f1-ab7a-020000000000","F",-1000,1000,14}},
["/mod/8/Offset"]={{"c974d45c-b290-11f1-8e85-020000000000","F",-1000,1000,14}},
["/voice/Polyphony"]={{"c974e154-b290-11f1-949e-020000000000","E",0,0,15},{"c974e1c2-b290-11f1-bab0-020000000000","E",1,1,15}},
["/voice/Unison"]={{"c974e348-b290-11f1-95de-020000000000","E",0,0,15},{"c974e3c0-b290-11f1-82ce-020000000000","E",1,1,15},{"c974e42e-b290-11f1-84b4-020000000000","E",2,2,15},{"c974e4a6-b290-11f1-93a2-020000000000","E",3,3,15}},
["/voice/UnisonDetune"]={{"c974e8de-b290-11f1-88e4-020000000000","F",0,100,15},{"c9750a94-b290-11f1-8c68-020000000000","F",0,100,15}},
["/voice/Portamento"]={{"c974e9e2-b290-11f1-844a-020000000000","E",0,0,15},{"c974ea50-b290-11f1-a3a6-020000000000","E",1,1,15},{"c974eac8-b290-11f1-a8b9-020000000000","E",2,2,15}},
["/voice/PortaType"]={{"c974edca-b290-11f1-85a2-020000000000","E",0,0,15},{"c974ee42-b290-11f1-9124-020000000000","E",1,1,15},{"c974eeb0-b290-11f1-b45e-020000000000","E",2,2,15},{"c974ef14-b290-11f1-8348-020000000000","E",3,3,15}},
["/voice/PortaTime"]={{"c974f32e-b290-11f1-8628-020000000000","F",0,127,15}},
["/voice/OSCSync"]={{"c974f432-b290-11f1-876b-020000000000","E",0,0,15},{"c974f4aa-b290-11f1-b2e6-020000000000","E",1,1,15},{"c974f518-b290-11f1-816b-020000000000","E",2,2,15},{"c974f586-b290-11f1-8979-020000000000","E",3,3,15},{"c974f91e-b290-11f1-b2a7-020000000000","E",4,4,15}},
["/voice/FMType"]={{"c974febe-b290-11f1-910b-020000000000","E",0,0,15},{"c975045e-b290-11f1-b78c-020000000000","E",1,1,15},{"c97504d6-b290-11f1-b785-020000000000","E",2,2,15},{"c9750544-b290-11f1-8c87-020000000000","E",3,3,15},{"c97505a8-b290-11f1-9e9c-020000000000","E",4,4,15},{"c9750620-b290-11f1-9962-020000000000","E",5,5,15}},
["/voice/FMAmount"]={{"c97503dc-b290-11f1-a3ea-020000000000","F",0,1000,15}},
["/voice/PitchWheel"]={{"c975079c-b290-11f1-99dd-020000000000","E",0,0,15},{"c975080a-b290-11f1-a2c2-020000000000","E",1,1,15}},
["/out/DriveType"]={{"c9750c1a-b290-11f1-8f51-020000000000","E",3,3,15},{"c9750c88-b290-11f1-9da9-020000000000","E",4,4,15},{"c9750cf6-b290-11f1-a34b-020000000000","E",5,5,15},{"c9750d6e-b290-11f1-b46f-020000000000","E",6,6,15},{"c9751228-b290-11f1-8bd9-020000000000","E",2,2,15},{"c9751318-b290-11f1-a087-020000000000","E",1,1,15},{"c9751408-b290-11f1-9ad9-020000000000","E",0,0,15}},
["/out/DriveLevel"]={{"c9751124-b290-11f1-98fd-020000000000","F",0,100,15}},
["/out/FxMix"]={{"c9751598-b290-11f1-8c32-020000000000","F",-50,50,15}},
["/out/ProgramLevel"]={{"c97517aa-b290-11f1-b3b3-020000000000","F",0,100,15}},
["/out/FxBalance"]={{"c975194e-b290-11f1-9bbd-020000000000","F",-50,50,15}},
}

local NRPN_PATH={}
for path,n in pairs(NRPN) do NRPN_PATH[n]=path end

----------------------------------------------------------------------
-- Controles: localizacion, actualizacion y deteccion de cambios
----------------------------------------------------------------------
local ENT=nil        -- todas las entradas
local BYPATH={}      -- direccion OSC -> entradas
local BYPAGE={}      -- pagina del pager -> entradas

local function buildEntries()
  if ENT then return end
  ENT={}
  BYPATH={}
  BYPAGE={}
  for path,l in pairs(CTL) do
    for i=1,#l do
      local d=l[i]
      local c=root:findByID(d[1],true)
      if c then
        local e={c=c,k=d[2],a=d[3],b=d[4],path=path,page=d[5],last=c.values.x}
        ENT[#ENT+1]=e
        if not BYPATH[path] then BYPATH[path]={} end
        BYPATH[path][#BYPATH[path]+1]=e
        if not BYPAGE[d[5]] then BYPAGE[d[5]]={} end
        BYPAGE[d[5]][#BYPAGE[d[5]]+1]=e
      end
    end
  end
  print('Controles localizados: '..#ENT)
end

-- Pone el valor "val" (en unidades del parametro) en una entrada y recuerda
-- el valor real resultante para que no cuente como cambio del usuario.
local function applyToEntry(e,val)
  local c=e.c
  if e.k=='E' then
    if math.floor(val+0.5)==e.a then c.values.x=1 else c.values.x=0 end
  else
    local n=0
    if e.b~=e.a then n=(val-e.a)/(e.b-e.a) end
    if n<0 then n=0 elseif n>1 then n=1 end
    c.values.x=n
  end
  e.last=c.values.x
end

local function setControls(path,val)
  local l=BYPATH[path]
  if not l then return end
  for i=1,#l do applyToEntry(l[i],val) end
end

-- Mientras se vuelca un patch los controles NO deben mandar sus mensajes
-- MIDI/OSC propios. Solo se silencian los controles que se actualizan y se
-- restauran un instante despues (TouchOSC envia los cambios al final del frame).
local muted=nil
local restoreAt=0

local function muteOutputs()
  if muted then return end
  buildEntries()
  muted={}
  for i=1,#ENT do
    local m=ENT[i].c.messages
    if m then
      local groups={m.MIDI,m.OSC}
      for g=1,2 do
        local l=groups[g]
        if l then
          for q=1,#l do
            local mm=l[q]
            if mm.send then
              muted[#muted+1]=mm
              mm.send=false
            end
          end
        end
      end
    end
  end
end

local function restoreOutputs()
  if not muted then return end
  for i=1,#muted do muted[i].send=true end
  muted=nil
end

-- Programas editados: copia de los controles al salir y restauracion al volver
local function saveSnapshot(key)
  if not ENT then return end
  local s={}
  for i=1,#ENT do s[i]=ENT[i].last end
  SNAP[key]=s
end

local function restoreSnapshot(key)
  local s=SNAP[key]
  if (not s) or (not ENT) then return false end
  muteOutputs()
  for i=1,#ENT do
    local e=ENT[i]
    if s[i]~=nil then
      e.c.values.x=s[i]
      e.last=e.c.values.x
    end
  end
  restoreAt=getMillis()+250
  return true
end

----------------------------------------------------------------------
-- TouchOSC -> Micron (NRPN)
----------------------------------------------------------------------
-- Alesis: CC99 (MSB) + CC98 (LSB) = parametro, CC6 (MSB) + CC38 (LSB) = valor
-- de 14 bits. Los negativos se mandan como 16384+valor (-100 -> 16284).
local function sendNRPN(path,val)
  if not SEND_NRPN then return end
  local n=NRPN[path]
  if not n then return end
  if curKey then dirty[curKey]=true end
  local v=math.floor(val+0.5)
  if v<0 then v=16384+v end
  if v>16383 then v=16383 end
  local st=176+midiChannel
  sendMIDI({st,99,math.floor(n/128)})
  sendMIDI({st,98,n%128})
  sendMIDI({st,6,math.floor(v/128)})
  sendMIDI({st,38,v%128})
  if DEBUG_NRPN then print(string.format('NRPN %d = %d  (%s, canal %d)',n,v,path,midiChannel+1)) end
end

local function valueOfEntry(e)
  return math.floor(e.a+e.last*(e.b-e.a)+0.5)
end

local function continuousSibling(path)
  local l=BYPATH[path]
  if not l then return nil end
  for i=1,#l do
    if l[i].k=='F' then return l[i] end
  end
  return nil
end

-- El usuario ha tocado un control
local function userChanged(e,x)
  e.last=x
  local val
  if e.k=='E' then
    if x>=0.5 then
      val=e.a
    else
      -- boton de grupo apagado a mano: si hay un fader de la misma direccion
      -- (p.ej. Sustain Time / boton "256") manda el valor del fader; si no,
      -- se comporta como radio y se vuelve a encender sin enviar nada.
      local sib=continuousSibling(e.path)
      if sib then
        val=valueOfEntry(sib)
      else
        e.c.values.x=1
        e.last=e.c.values.x
        return
      end
    end
  else
    val=math.floor(e.a+x*(e.b-e.a)+0.5)
  end
  -- refleja el cambio en las demas vistas del mismo parametro / botones del grupo
  local l=BYPATH[e.path]
  for i=1,#l do
    if l[i]~=e then applyToEntry(l[i],val) end
  end
  sendNRPN(e.path,val)
end

local pager=nil
local function currentPage()
  if not pager then pager=root:findByName('pager1',true) end
  if not pager then return nil end
  return pager.values.page
end

local function pollUser()
  if not ENT then return end
  local pg=currentPage()
  local list=nil
  if pg then list=BYPAGE[pg] end
  if not list then list=ENT end
  for i=1,#list do
    local e=list[i]
    local x=e.c.values.x
    if x~=e.last then userChanged(e,x) end
  end
end

----------------------------------------------------------------------
-- Micron -> TouchOSC (NRPN recibidos)
----------------------------------------------------------------------
local rxMsb=0
local rxLsb=0
local rxData=0

local function applyRxNRPN(dataLsb)
  buildEntries()
  local n=(rxMsb*128+rxLsb)%256      -- x / y / z = +0 / +256 / +512
  local path=NRPN_PATH[n]
  if not path then return end
  if curKey then dirty[curKey]=true end
  local v=rxData*128+dataLsb
  if v>=8192 then v=v-16384 end
  setControls(path,v)
  if DEBUG_NRPN then print(string.format('NRPN RX %d = %d  (%s)',n,v,path)) end
end

----------------------------------------------------------------------
-- Volcado SysEx -> controles
----------------------------------------------------------------------
local syncContent=nil
local syncVals=nil
local syncIndex=0
local syncActive=false
local syncBytes=0
local syncName=''
local syncKind='menu'
local syncLoc=nil

local function applyParam(i)
  local p=params[i]
  local v=readBits(syncContent,p[4],p[2],p[3])
  syncVals[i]=v
  if string.sub(p[1],1,7)=="dummy::" then return end
  local c=p[5]
  if c~='' then
    local f=CONV[c]
    if f then v=f(v,i,syncVals) end
  end
  setControls(pathOf[i],v)
end

local function startAutoSync(msg)
  local hdr={}
  for i=1,math.min(#msg,14) do hdr[#hdr+1]=msg[i] end
  print('SYSEX IN: '..#msg..' bytes; inicio: '..table.concat(hdr,' '))
  local d,why,model=decode7to8(msg)
  if not d then
    print('AUTO-SYNC: sysex ignorado -> '..why)
    return
  end
  if #d<60 then
    print('AUTO-SYNC: sysex incompleto ('..#d..' bytes decodificados)')
    return
  end
  -- nombre del patch: bytes 63..77 del PDF (d[j] equivale al byte j+6)
  local nm={}
  for k=63,77 do
    local c=d[k-6] or 0
    if c==0 then break end
    if c>=32 and c<=126 then nm[#nm+1]=string.char(c) end
  end
  print('PATCH: "'..table.concat(nm)..'"  (cabecera bank='..msg[7]..' multiple='..msg[8]..' slot='..msg[9]..')')
  syncName=table.concat(nm)
  local tnow=getMillis()
  syncLoc=nil
  if tnow<manualUntil then
    syncKind='manual'
    manualUntil=0
  elseif tnow<expectUntil then
    syncKind='auto'
  else
    syncKind='menu'
  end
  -- Deteccion de canal: en un REFRESH manual o un volcado del menu no hay
  -- espera, asi que el canal actual (lastRxChannel) es de fiar. En un AUTO
  -- (dispara por Program Change) puede pasar tiempo hasta que llega el
  -- SysEx, asi que usamos el canal capturado justo cuando se armo la
  -- peticion, no el que haya quedado luego.
  if syncKind=='auto' then
    if autoReqChannel then
      autoDetectChannel(autoReqChannel)
      autoReqChannel=nil
    end
  else
    autoDetectChannel(lastRxChannel)
  end
  if lastReqKey and tnow<expectUntil and REQUEST_MODE~=4 then
    syncLoc=string.format(' (bank %d, patch %d)',math.floor(lastReqKey/128),lastReqKey%128)
  end
  if DEBUG_SYSEX then
    local t={}
    for k=93,108 do t[#t+1]=string.format('%d:%02X',k,d[k-6] or 0) end
    print('BYTES PDF '..table.concat(t,' '))
  end
  -- Max: byteDecode -> quitar los 56 primeros bytes decodificados -> contenido
  syncContent={}
  for i=57,#d do syncContent[#syncContent+1]=d[i] end
  syncVals={}
  syncIndex=0
  syncBytes=#d
  if not syncActive then muteOutputs() end
  syncActive=true
  print('AUTO-SYNC: '..#d..' bytes decodificados; iniciando')
end

-- Proteccion contra volcados masivos ("Send all sysex" del Micron): si llegan
-- varios SysEx seguidos no se pide ni se aplica nada hasta que haya calma.
local lastSysexAt=-100000
local sysexBurst=0
local quietUntil=0

-- Botones AUTO del layout (uno por pagina): se mantienen todos en el mismo estado
local function setAutoButtons(on)
  local v=0
  if on then v=1 end
  for i=1,#AUTO_BTN_IDS do
    local c=root:findByID(AUTO_BTN_IDS[i],true)
    if c and c.values.x~=v then c.values.x=v end
  end
end

-- Texto de estado junto a los botones (una etiqueta por pagina)
local statusCtl=nil
local statusClearAt=0
local function setStatus(text,ms)
  if not statusCtl then
    statusCtl={}
    for i=1,#STATUS_IDS do statusCtl[i]=root:findByID(STATUS_IDS[i],true) end
  end
  for i=1,#STATUS_IDS do
    local c=statusCtl[i]
    if c then c.values.text=text end
  end
  if ms and ms>0 then statusClearAt=getMillis()+ms else statusClearAt=0 end
end

-- Selector de canal MIDI: un fader de 16 posiciones (canales 1-16), uno
-- por pagina, todas se mueven y muestran el mismo valor a la vez.
local CHANNEL_STEPS=16
local channelLblCtl=nil
local channelFaderCtl=nil
local function channelText()
  return 'CH '..(midiChannel+1)
end
local function channelStep()
  return midiChannel
end
local function updateChannelSelectors()
  if not channelLblCtl then
    channelLblCtl={}
    for i=1,#CHANNEL_LBL_IDS do channelLblCtl[i]=root:findByID(CHANNEL_LBL_IDS[i],true) end
  end
  if not channelFaderCtl then
    channelFaderCtl={}
    for i=1,#CHANNEL_FADER_IDS do channelFaderCtl[i]=root:findByID(CHANNEL_FADER_IDS[i],true) end
  end
  local t=channelText()
  local x=(channelStep()+0.5)/CHANNEL_STEPS
  for i=1,#channelLblCtl do
    local c=channelLblCtl[i]
    if c then c.values.text=t end
  end
  for i=1,#channelFaderCtl do
    local c=channelFaderCtl[i]
    if c and math.abs(c.values.x-x)>0.001 then c.values.x=x end
  end
end
local function setChannelStep(step)
  if step<0 then step=0 end
  if step>CHANNEL_STEPS-1 then step=CHANNEL_STEPS-1 end
  midiChannel=step
  updateChannelSelectors()
  setStatus('MIDI channel: '..channelText(),2000)
end
-- Deteccion automatica: cuando llega un volcado SysEx valido del Micron,
-- si justo antes vimos un CC o Program Change por un canal distinto al
-- que tenemos puesto, asumimos que ese es el canal real del Micron (los
-- sintetizadores usan el mismo canal para recibir y para transmitir) y
-- movemos el fader solos, sin tocar nada mas.
autoDetectChannel=function(ch)
  if ch and ch~=midiChannel then
    setChannelStep(ch)
    setStatus('MIDI channel detected: '..channelText(),3000)
  end
end

function init()
  ENT=nil
  pager=nil
  statusCtl=nil
  channelLblCtl=nil
  buildEntries()
  setAutoButtons(AUTO_REQUEST)
  updateChannelSelectors()
end

function update()
  local now=getMillis()
  if statusClearAt>0 and now>=statusClearAt then setStatus('',0) end
  if refreshArmedAt>0 and now-refreshArmedAt>5000 then
    refreshArmedAt=0
    setStatus('Refresh cancelled - program left unchanged.',2500)
  end
  -- Dar tiempo al Micron a cargar el programa; el patch se lee SOLO del SysEx.
  if pendingRequest and now>=requestDue then
    pendingRequest=false
    if now<quietUntil then
      print('Peticion omitida: volcado SysEx en curso')
    else
      local b,p=currentLocation()
      if b==nil then
        if REQUEST_MODE==4 then requestPatch(0,0)
        else
          print('Aun no se conoce el programa actual: cambia de programa una vez en el Micron')
          setStatus('Select any program on the Micron once, then press REFRESH.',4000)
        end
      else
        requestPatch(b,p)
      end
    end
  end
  if muted and (not syncActive) and now>=restoreAt then restoreOutputs() end
  if not syncActive then
    if SEND_NRPN then pollUser() end
    return
  end
  local last=math.min(syncIndex+48,#params)
  for i=syncIndex+1,last do applyParam(i) end
  syncIndex=last
  if syncIndex>=#params then
    syncActive=false
    syncContent=nil
    syncVals=nil
    restoreAt=now+250
    print('AUTO-SYNC OK: '..syncBytes..' bytes; '..#params..' parametros')
    local loc=syncLoc or ''
    if syncKind=='manual' then
      setStatus('Refreshed and saved - '..syncName..loc,3500)
    elseif syncKind=='auto' then
      setStatus('Loaded: '..syncName..loc,2500)
    else
      setStatus('Received from Micron: '..syncName,2500)
    end
  end
end

function onReceiveMIDI(message,connections)
  if not message or #message==0 then return end
  local status=message[1]
  if #message>=3 and status>=176 and status<=191 then
    lastRxChannel=status-176
    local cc=message[2]
    local v=message[3]
    if cc==0 then
      bank0=v
      print('RX CC0 (banco MSB) = '..v)
    elseif cc==32 then
      bank32=v
      print('RX CC32 (banco LSB) = '..v)
    end
    if RECEIVE_NRPN and (not syncActive) then
      if cc==99 then rxMsb=v
      elseif cc==98 then rxLsb=v
      elseif cc==6 then rxData=v
      elseif cc==38 then applyRxNRPN(v) end
    end
    return true
  end
  if status>=192 and status<=207 and #message>=2 then
    lastRxChannel=status-192
    curProg=message[2]
    local b,p=currentLocation()
    local now=getMillis()
    local key=b*128+p
    if now<ignoreUntil and key==lastReqKey then
      print('RX PROGRAM CHANGE '..message[2]..' (eco de la lectura: se ignora)')
      curKey=key
    else
      print('RX PROGRAM CHANGE '..message[2]..'  [CC0='..tostring(bank0)..' CC32='..tostring(bank32)..']  -> banco '..b..' patch '..p)
      -- copia del programa que se deja, si lo editaste desde TouchOSC
      if PROTECT_EDITED and curKey and curKey~=key and dirty[curKey] then
        saveSnapshot(curKey)
      end
      curKey=key
      if AUTO_REQUEST then
        if PROTECT_EDITED and dirty[key] and SNAP[key] then
          pendingRequest=false
          restoreSnapshot(key)
          print('Programa editado: se restaura tu version (no se pide al Micron para no guardarlo)')
          setStatus('Edited program restored from TouchOSC (not read from the Micron, so it is not saved).',3500)
        else
          pendingRequest=true
          requestDue=now+REQUEST_DELAY_MS
          autoReqChannel=lastRxChannel
        end
      end
    end
    return true
  end
  if status==240 then
    local now=getMillis()
    if now>=expectUntil then
      -- volcado que no hemos pedido: si llegan varios seguidos es un "send all"
      if now-lastSysexAt<1000 then sysexBurst=sysexBurst+1 else sysexBurst=1 end
      lastSysexAt=now
      if sysexBurst>=3 or now<quietUntil then
        if now>=quietUntil then print('*** VOLCADO SYSEX MASIVO detectado: se ignoran SysEx y peticiones ***') end
        quietUntil=now+4000
        pendingRequest=false
        return true
      end
    end
    print('*** SYSEX RECIBIDO - AUTO SYNC ***')
    startAutoSync(message)
    return true
  end
end

-- Avisos de los botones REFRESH / AUTO de cada pagina
function onReceiveNotify(key,value)
  if key=='channel' then
    setChannelStep(value)
  elseif key=='refresh' then
    local now=getMillis()
    if PROTECT_EDITED and curKey and dirty[curKey] then
      if now-refreshArmedAt>5000 then
        refreshArmedAt=now
        print('REFRESH: este programa esta editado y leerlo lo guardaria en el Micron. Pulsa REFRESH otra vez (5 s) para confirmar.')
        setStatus('EDITED PROGRAM - reading it will SAVE it on the Micron. Press REFRESH again to confirm.',5000)
        return
      end
      dirty[curKey]=nil
      SNAP[curKey]=nil
      refreshArmedAt=0
    end
    manualUntil=now+3000
    print('REFRESH manual')
    quietUntil=0
    pendingRequest=true
    requestDue=getMillis()
  elseif key=='auto' then
    AUTO_REQUEST=(value~=nil and value>=0.5)
    if AUTO_REQUEST then print('AUTO-UPDATE: ON') else print('AUTO-UPDATE: OFF') end
    setAutoButtons(AUTO_REQUEST)
  end
end