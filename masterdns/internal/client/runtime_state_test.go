package client

import (
	"context"
	"errors"
	"testing"
	"time"
)

func newRuntimeStateTestClient() *Client {
	return &Client{
		initialReady: make(chan struct{}),
		stopped:      make(chan struct{}),
	}
}

func TestWaitUntilReadyReleasesAfterRuntimeStarts(t *testing.T) {
	c := newRuntimeStateTestClient()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- c.WaitUntilReady(ctx) }()

	c.markRuntimeReady()
	if err := <-done; err != nil {
		t.Fatalf("WaitUntilReady: %v", err)
	}
	if !c.RuntimeReady() {
		t.Fatal("RuntimeReady must be true after markRuntimeReady")
	}
}

func TestWaitUntilReadyReleasesWhenStopped(t *testing.T) {
	c := newRuntimeStateTestClient()
	done := make(chan error, 1)
	go func() { done <- c.WaitUntilReady(context.Background()) }()
	c.SignalStopped()
	if err := <-done; !errors.Is(err, ErrClientStoppedBeforeReady) {
		t.Fatalf("WaitUntilReady error = %v, want ErrClientStoppedBeforeReady", err)
	}
}

func TestWaitUntilReadyTimesOut(t *testing.T) {
	c := newRuntimeStateTestClient()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if err := c.WaitUntilReady(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("WaitUntilReady error = %v, want deadline exceeded", err)
	}
}
