package libbox

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"strings"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

// ProbeProxyGET starts an isolated core without a TUN and checks URLs with GET
// through the requested outbound. A positive value is the elapsed time in ms.
// No URL, host, credentials, or response body are returned to the UI.
func ProbeProxyGET(configContent string, link string, platform PlatformInterface) (int32, error) {
	ctx := baseContext(platform)
	if platform != nil {
		wrapper := &platformInterfaceWrapper{iif: platform, useProcFS: platform.UseProcFS()}
		service.MustRegister[adapter.PlatformInterface](ctx, wrapper)
	}
	options, err := parseConfig(ctx, configContent)
	if err != nil {
		return 0, err
	}
	if len(options.Inbounds) != 0 {
		return 0, &probeConfigError{}
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	instance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		return 0, err
	}
	defer instance.Close()
	if err = instance.PreStart(); err != nil {
		return 0, err
	}
	outbound, found := instance.Outbound().Outbound("proxy")
	if !found {
		return 0, &probeConfigError{}
	}
	dial := func(ctx context.Context, network string, address string) (net.Conn, error) {
		return outbound.DialContext(ctx, "tcp", M.ParseSocksaddr(address))
	}
	return probeTargets(ctx, link, dial)
}

func probeTargets(ctx context.Context, link string, dial func(context.Context, string, string) (net.Conn, error)) (int32, error) {
	var lastErr error
	for _, target := range strings.Split(link, "\n") {
		if target == "" {
			continue
		}
		delay, err := probeGET(ctx, target, dial)
		if err == nil {
			return delay, nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = &probeConfigError{}
	}
	return 0, lastErr
}

func probeGET(ctx context.Context, link string, dial func(context.Context, string, string) (net.Conn, error)) (int32, error) {
	transport := &http.Transport{
		DisableKeepAlives: true,
		TLSClientConfig:   &tls.Config{RootCAs: adapter.RootPoolFromContext(ctx)},
		DialContext:       dial,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 4 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return 0, err
	}
	started := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return 0, err
	}
	response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 400 {
		return 0, &probeResponseError{}
	}
	elapsed := time.Since(started).Milliseconds()
	if elapsed < 1 {
		elapsed = 1
	}
	return int32(elapsed), nil
}

type probeConfigError struct{}

func (*probeConfigError) Error() string { return "invalid proxy probe configuration" }

type probeResponseError struct{}

func (*probeResponseError) Error() string { return "proxy probe returned an error status" }
