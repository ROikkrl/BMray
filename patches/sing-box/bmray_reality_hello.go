//go:build with_utls

package tls

import (
 "net"
 utls "github.com/metacubex/utls"
)

// Xray >= 26.9.8 requires ML-KEM before X25519. Preserve Chrome's hybrid
// key shares and modernize the pinned Firefox preset's key exchange only.
func bmrayRealityHello(conn net.Conn, config *utls.Config, id utls.ClientHelloID) (*utls.UConn, error) {
 c := utls.UClient(conn, config, id)
 if id.Client == utls.HelloFirefox_Auto.Client {
  spec, err := utls.UTLSIdToSpec(id)
  if err != nil { return nil, err }
  for _, ext := range spec.Extensions {
   switch e := ext.(type) {
   case *utls.SupportedCurvesExtension:
    e.Curves = append([]utls.CurveID{utls.X25519MLKEM768}, e.Curves...)
   case *utls.KeyShareExtension:
    e.KeyShares = append([]utls.KeyShare{{Group:utls.X25519MLKEM768}},e.KeyShares...)
   }
  }
  c = utls.UClient(conn, config, utls.HelloCustom)
  if err := c.ApplyPreset(&spec); err != nil { return nil, err }
 }
 if err := c.BuildHandshakeState(); err != nil { return nil, err }
 return c,nil
}
