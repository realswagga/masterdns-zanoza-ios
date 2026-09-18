package client

import (
	"context"
	"sort"
)

// ResolverMTUScanResult is a stable, mobile-facing snapshot of MasterDNS's
// real protocol probe. It is intentionally independent of log parsing.
type ResolverMTUScanResult struct {
	Resolver         string  `json:"resolver"`
	Port             int     `json:"port"`
	Domain           string  `json:"domain"`
	Accepted         bool    `json:"accepted"`
	ProbeSucceeded   bool    `json:"probeSucceeded"`
	Status           string  `json:"status"`
	UploadMTU        int     `json:"uploadMTU"`
	UploadCharacters int     `json:"uploadCharacters"`
	DownloadMTU      int     `json:"downloadMTU"`
	TunnelLatencyMS  float64 `json:"tunnelLatencyMS"`
}

// RunResolverMTUScan executes exactly the same encrypted, domain-aware MTU
// probes used during client startup, then returns per-resolver measurements.
// An optimizer-dropped resolver remains distinguishable from a protocol
// failure because its measured MTUs are retained.
func (c *Client) RunResolverMTUScan(ctx context.Context) ([]ResolverMTUScanResult, error) {
	err := c.RunInitialMTUTests(ctx)
	connections := c.balancer.AllConnections()
	results := make([]ResolverMTUScanResult, 0, len(connections))
	for _, conn := range connections {
		probeSucceeded := conn.UploadMTUBytes > 0 && conn.DownloadMTUBytes > 0
		status := "accepted"
		switch {
		case conn.IsValid:
			status = "accepted"
		case probeSucceeded:
			status = "optimizer_dropped"
		case conn.UploadMTUBytes <= 0:
			status = "upload_mtu_failed"
		default:
			status = "download_mtu_failed"
		}
		results = append(results, ResolverMTUScanResult{
			Resolver:         conn.Resolver,
			Port:             conn.ResolverPort,
			Domain:           conn.Domain,
			Accepted:         conn.IsValid,
			ProbeSucceeded:   probeSucceeded,
			Status:           status,
			UploadMTU:        conn.UploadMTUBytes,
			UploadCharacters: conn.UploadMTUChars,
			DownloadMTU:      conn.DownloadMTUBytes,
			TunnelLatencyMS:  float64(conn.MTUResolveTime.Microseconds()) / 1000.0,
		})
	}
	sort.SliceStable(results, func(i, j int) bool {
		if results[i].Resolver == results[j].Resolver {
			return results[i].Port < results[j].Port
		}
		return results[i].Resolver < results[j].Resolver
	})
	return results, err
}
