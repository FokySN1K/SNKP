package core

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

// okServer answers every probe, so a test measures a completed dial.
func okServer(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)
	return server
}

// The app can show the road to a node apart from its delay, and a node tested
// on its own updates only through this result: the history a group sweep
// leaves is not what a single test returns.
func TestTestDelayReportsTheRoadTime(t *testing.T) {
	server := okServer(t)

	tunnel.UpdateProxies(map[string]constant.Proxy{"road": namedProxy("road")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	delay := handleTestDelay(&TestDelayParams{
		ProxyName: "road",
		TestUrl:   server.URL,
		Timeout:   defaultDelayTestTimeout.Milliseconds(),
	})
	if delay == nil {
		t.Fatal("handleTestDelay gave up on a slot it should have been handed")
	}
	if delay.Value <= 0 {
		t.Fatalf("value = %d, want a measured delay for a reachable node", delay.Value)
	}
	if delay.Rtt <= 0 {
		t.Fatalf("rtt = %d, want the road time of a completed dial", delay.Rtt)
	}
	if delay.Rtt > delay.Value {
		t.Errorf("rtt = %d above delay = %d, want the dial to fit inside the whole test", delay.Rtt, delay.Value)
	}
}

// balanceOverTarget builds a load balancer that checks its members against
// url, so a test of the group's own check has a target of its own rather than
// the default one.
func balanceOverTarget(t *testing.T, name, url string, members ...constant.Proxy) constant.Proxy {
	t.Helper()

	health := provider.NewHealthCheck(members, url, 0, 0, true, nil)
	pd, err := provider.NewCompatibleProvider(name+"-provider", members, health)
	if err != nil {
		t.Fatalf("NewCompatibleProvider: %v", err)
	}
	group, err := outboundgroup.NewLoadBalance(
		outboundgroup.GroupCommonOption{Name: name, URL: url},
		outboundgroup.LoadBalanceOption{Strategy: "round-robin"},
		namedProxy("COMPATIBLE"),
		[]cp.ProxyProvider{pd},
	)
	if err != nil {
		t.Fatalf("NewLoadBalance: %v", err)
	}
	return adapter.NewProxy(group)
}

// A group header shows the road of the route the group took. A load balancer
// names no single route, so the member its delay reports is the one whose road
// time the header shows.
func TestTestGroupDelayReportsTheRoadTimeOfItsRoute(t *testing.T) {
	server := okServer(t)

	members := []constant.Proxy{namedProxy("road-a"), namedProxy("road-b")}
	balance := balanceOverTarget(t, "Roads", server.URL, members...)
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"Roads":  balance,
		"road-a": members[0],
		"road-b": members[1],
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	delay := handleTestGroupDelay(&TestDelayParams{
		ProxyName: "Roads",
		Timeout:   defaultDelayTestTimeout.Milliseconds(),
	})
	if delay == nil {
		t.Fatal("handleTestGroupDelay gave up on a slot it should have been handed")
	}
	if delay.Value <= 0 {
		t.Fatalf("value = %d, want a measured delay for a reachable group", delay.Value)
	}
	if delay.Rtt <= 0 {
		t.Fatalf("rtt = %d, want the road time of the member the group's delay describes", delay.Rtt)
	}
	if delay.Rtt > delay.Value {
		t.Errorf("rtt = %d above delay = %d, want the dial to fit inside the whole test", delay.Rtt, delay.Value)
	}
}
