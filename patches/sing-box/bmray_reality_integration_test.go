//go:build with_utls

package tls

import (
 "context"
 "crypto/ecdh"
 "crypto/rand"
 stdtls "crypto/tls"
 "crypto/x509"
 "encoding/base64"
 "encoding/json"
 "fmt"
 "io"
 "net"
 "net/http"
 "net/http/httptest"
 "os"
 "os/exec"
 "path/filepath"
 "strings"
 "testing"
 "time"
 "github.com/sagernet/sing-box/option"
 "github.com/sagernet/sing-vmess/vless"
 "github.com/sagernet/sing/common/logger"
 M "github.com/sagernet/sing/common/metadata"
)

// Real Xray, entirely on loopback with freshly generated test-only keys.
// Checks authenticated HTTPS payloads and rejects incorrect keys/short IDs.
func TestBMrayRealityXray(t *testing.T) {
 binary:=os.Getenv("BMRAY_TEST_XRAY")
 if binary=="" {t.Skip("set BMRAY_TEST_XRAY to the pinned Xray binary")}
 legacy:=os.Getenv("BMRAY_EXPECT_LEGACY_FAILURE")=="1"
 decoy:=httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){w.WriteHeader(204)}))
 decoy.TLS=&stdtls.Config{MinVersion:stdtls.VersionTLS13,CurvePreferences:[]stdtls.CurveID{stdtls.X25519}}
 decoy.EnableHTTP2=true
 decoy.StartTLS();defer decoy.Close()
 payload:=strings.Repeat("BMray authenticated VLESS traffic\n",4096)
 destination:=httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){io.WriteString(w,payload)}))
 defer destination.Close()
 roots:=x509.NewCertPool();roots.AddCert(destination.Certificate())
 key,err:=ecdh.X25519().GenerateKey(rand.Reader);if err!=nil {t.Fatal(err)}
 wrongKey,err:=ecdh.X25519().GenerateKey(rand.Reader);if err!=nil {t.Fatal(err)}
 encode:=base64.RawURLEncoding.EncodeToString
 const uuid="00000000-0000-4000-8000-000000000001"
 const sid="0123456789abcdef"
 listener,err:=net.Listen("tcp","127.0.0.1:0");if err!=nil {t.Fatal(err)}
 port:=listener.Addr().(*net.TCPAddr).Port;listener.Close()
 address:=fmt.Sprintf("127.0.0.1:%d",port)
 config:=map[string]any{
  "log":map[string]any{"loglevel":"debug"},
  "inbounds":[]any{map[string]any{
   "listen":"127.0.0.1","port":port,"protocol":"vless",
   "settings":map[string]any{"decryption":"none","clients":[]any{map[string]any{"id":uuid,"flow":"xtls-rprx-vision"}}},
   "streamSettings":map[string]any{"network":"tcp","security":"reality","realitySettings":map[string]any{
    "dest":decoy.Listener.Addr().String(),"serverNames":[]string{"example.com"},
    "privateKey":encode(key.Bytes()),"shortIds":[]string{sid},"maxTimeDiff":60000,
   }},
  }},
  // Xray's default freedom policy blocks loopback. Permit only this local
  // test destination; this configuration is never shipped to users.
  "outbounds":[]any{map[string]any{"protocol":"freedom","settings":map[string]any{"finalRules":[]any{map[string]any{"action":"allow","ip":[]string{"127.0.0.1/32"}}}}}},
 }
 dir:=t.TempDir();data,_:=json.Marshal(config)
 if err=os.WriteFile(filepath.Join(dir,"server.json"),data,0600);err!=nil {t.Fatal(err)}
 logFile,err:=os.Create(filepath.Join(dir,"server.log"));if err!=nil {t.Fatal(err)}
 cmd:=exec.Command(binary,"run","-c",filepath.Join(dir,"server.json"));cmd.Stdout=logFile;cmd.Stderr=logFile
 if err=cmd.Start();err!=nil {t.Fatal(err)}
 defer func(){cmd.Process.Kill();cmd.Wait();logFile.Close();if t.Failed(){b,_:=os.ReadFile(logFile.Name());t.Log(string(b))}}()
 deadline:=time.Now().Add(10*time.Second)
 for {c,e:=net.DialTimeout("tcp",address,100*time.Millisecond);if e==nil {c.Close();break};if time.Now().After(deadline){t.Fatal("Xray did not start")};time.Sleep(25*time.Millisecond)}
 for _,fp:=range []string{"firefox","chrome"} {
  for _,invalid:=range []string{"valid","key","short_id"} {
   if legacy && invalid!="valid" {continue}
   t.Run(fp+"/"+invalid,func(t *testing.T){
    publicKey:=encode(key.PublicKey().Bytes());shortID:=sid
    if invalid=="key" {publicKey=encode(wrongKey.PublicKey().Bytes())}
    if invalid=="short_id" {shortID="ffffffffffffffff"}
    ctx,cancel:=context.WithTimeout(context.Background(),20*time.Second);defer cancel()
    cfg,e:=NewRealityClient(ctx,logger.NOP(),"127.0.0.1",option.OutboundTLSOptions{Enabled:true,ServerName:"example.com",UTLS:&option.OutboundUTLSOptions{Enabled:true,Fingerprint:fp},Reality:&option.OutboundRealityOptions{Enabled:true,PublicKey:publicKey,ShortID:shortID}})
    if e!=nil {t.Fatal(e)}
    raw,e:=(&net.Dialer{}).DialContext(ctx,"tcp",address);if e!=nil {t.Fatal(e)};defer raw.Close()
    raw.SetDeadline(time.Now().Add(20*time.Second))
    secured,e:=cfg.(*RealityClientConfig).ClientHandshake(ctx,raw)
    if invalid!="valid" || legacy {if e==nil {secured.Close();t.Fatal("unauthenticated/legacy handshake was accepted")};t.Log("expected rejection:",e);return}
    if e!=nil {t.Fatal("REALITY handshake:",e)}
    client,e:=vless.NewClient(uuid,"xtls-rprx-vision",logger.NOP());if e!=nil {t.Fatal(e)}
    conn,e:=client.DialEarlyConn(secured,M.ParseSocksaddr(destination.Listener.Addr().String()));if e!=nil {t.Fatal(e)};defer conn.Close()
    transport:=&http.Transport{TLSClientConfig:&stdtls.Config{RootCAs:roots},DialContext:func(context.Context,string,string)(net.Conn,error){return conn,nil},DisableKeepAlives:true}
    defer transport.CloseIdleConnections()
    request,_:=http.NewRequestWithContext(ctx,"GET",destination.URL,nil)
    response,e:=(&http.Client{Transport:transport}).Do(request);if e!=nil {t.Fatal("HTTPS over VLESS Vision:",e)}
    body,e:=io.ReadAll(response.Body);response.Body.Close();if e!=nil {t.Fatal(e)}
    if response.StatusCode!=200 || string(body)!=payload {t.Fatal("tunnel payload mismatch")}
    t.Logf("authenticated HTTPS through VLESS Vision: %d bytes",len(body))
   })
  }
 }
}
