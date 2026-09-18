package client

import (
	"context"
	"errors"
)

var ErrClientStoppedBeforeReady = errors.New("client stopped before tunnel became ready")

func (c *Client) markRuntimeReady() {
	if c == nil {
		return
	}
	c.runtimeReady.Store(true)
	c.initialReadyOnce.Do(func() { close(c.initialReady) })
}

// RuntimeReady reports whether the current MasterDNS session and local proxy
// listeners are active. It becomes false during a resolver/session restart.
func (c *Client) RuntimeReady() bool {
	return c != nil && c.runtimeReady.Load()
}

// WaitUntilReady waits for the first fully initialized session. Unlike mobile
// Start, this does not treat successful goroutine creation as tunnel readiness.
func (c *Client) WaitUntilReady(ctx context.Context) error {
	if c == nil {
		return ErrClientStoppedBeforeReady
	}
	if c.RuntimeReady() {
		return nil
	}
	select {
	case <-c.initialReady:
		return nil
	case <-c.stopped:
		return ErrClientStoppedBeforeReady
	case <-ctx.Done():
		return ctx.Err()
	}
}

// SignalStopped releases readiness waiters when Run exits before a session is
// established. It is called by the mobile lifecycle shim.
func (c *Client) SignalStopped() {
	if c == nil {
		return
	}
	c.runtimeReady.Store(false)
	c.stoppedOnce.Do(func() { close(c.stopped) })
}
