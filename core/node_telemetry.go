package core

import (
	"time"

	"github.com/metacubex/mihomo/component/reputation"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// The SNKP telemetry asks the core for two snapshots the plain clash API does
// not expose: what every outbound node carried and how the nodes behaved when
// real traffic went through them. Both are read only; the app turns the totals
// into deltas before reporting.

type NodeTraffic struct {
	GeneratedAt time.Time             `json:"generated_at"`
	Nodes       []statistic.NodeUsage `json:"nodes"`
}

type NodeReliability struct {
	GeneratedAt time.Time                  `json:"generated_at"`
	Nodes       []reputation.SnapshotEntry `json:"nodes"`
}

func handleGetNodeTraffic() NodeTraffic {
	return NodeTraffic{
		GeneratedAt: time.Now(),
		Nodes:       statistic.DefaultManager.NodeSnapshot(),
	}
}

func handleGetReputation() NodeReliability {
	return NodeReliability{
		GeneratedAt: time.Now(),
		Nodes:       reputation.Default().Snapshot(),
	}
}
