package libbox

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBMrayProbeProxyGET(t *testing.T) {
	var method string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method = r.Method
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	delay, err := probeGET(context.Background(), server.URL,
		func(ctx context.Context, network string, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		})
	if err != nil || delay < 1 || method != http.MethodGet {
		t.Fatalf("GET via outbound: delay=%d err=%v method=%q", delay, err, method)
	}
}
