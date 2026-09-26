package libbox

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestBMrayProbeProxyGET(t *testing.T) {
	var method string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		method = r.Method
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	delay, err := probeGET(context.Background(), server.URL, 4*time.Second,
		func(ctx context.Context, network string, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		})
	if err != nil || delay < 1 || method != http.MethodGet {
		t.Fatalf("GET via outbound: delay=%d err=%v method=%q", delay, err, method)
	}
}

func TestBMrayProbeFallsBackWhenFirstTargetFails(t *testing.T) {
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer bad.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("unexpected method %s", r.Method)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer good.Close()
	delay, err := probeTargets(context.Background(), bad.URL+"\n"+good.URL, 4*time.Second,
		func(ctx context.Context, network string, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		})
	if err != nil || delay < 1 {
		t.Fatalf("fallback: delay=%d err=%v", delay, err)
	}
}

func TestBMrayProbeRespectsTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	_, err := probeGET(context.Background(), server.URL, 40*time.Millisecond,
		func(ctx context.Context, network string, address string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, address)
		})
	if err == nil {
		t.Fatal("expected the configured GET timeout")
	}
}
