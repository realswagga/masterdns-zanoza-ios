package client

import (
	"bufio"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"masterdnsvpn-go/internal/arq"
	"masterdnsvpn-go/internal/config"
	VpnProto "masterdnsvpn-go/internal/vpnproto"
)

func TestHTTPProxyAuthorization(t *testing.T) {
	c := &Client{cfg: config.ClientConfig{SOCKS5User: "alice", SOCKS5Pass: "secret"}}
	valid := "Basic " + base64.StdEncoding.EncodeToString([]byte("alice:secret"))
	if !c.validHTTPProxyAuthorization(valid) {
		t.Fatal("valid Basic proxy authorization was rejected")
	}
	if !c.validHTTPProxyAuthorization(strings.ToLower(valid[:5]) + valid[5:]) {
		t.Fatal("authorization scheme must be case-insensitive")
	}
	for _, value := range []string{"", "Bearer token", "Basic !!!", "Basic " + base64.StdEncoding.EncodeToString([]byte("alice:wrong"))} {
		if c.validHTTPProxyAuthorization(value) {
			t.Fatalf("invalid proxy authorization accepted: %q", value)
		}
	}
}

func TestWriteHTTPProxyErrorFormatsResponse(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	done := make(chan error, 1)
	go func() { done <- writeHTTPProxyError(server, 405) }()
	reply := make([]byte, 256)
	n, err := client.Read(reply)
	if err != nil {
		t.Fatalf("read proxy error: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("writeHTTPProxyError: %v", err)
	}
	text := string(reply[:n])
	if !strings.HasPrefix(text, "HTTP/1.1 405 Method Not Allowed\r\n") {
		t.Fatalf("unexpected proxy response: %q", text)
	}
	if !strings.Contains(text, "Content-Length: 0\r\n") {
		t.Fatalf("missing empty content length: %q", text)
	}
}

func TestBufferedProxyConnPreservesReadAheadPayload(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	reader := bufio.NewReader(server)
	go func() {
		_, _ = client.Write([]byte("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nearly-tls"))
	}()
	request, err := http.ReadRequest(reader)
	if err != nil {
		t.Fatalf("ReadRequest: %v", err)
	}
	_ = request.Body.Close()
	wrapped := &bufferedProxyConn{Conn: server, reader: reader}
	payload := make([]byte, len("early-tls"))
	if _, err := io.ReadFull(wrapped, payload); err != nil {
		t.Fatalf("read buffered payload: %v", err)
	}
	if string(payload) != "early-tls" {
		t.Fatalf("payload = %q, want early-tls", payload)
	}
}

func TestOptimisticSOCKSAcknowledgementDoesNotStartPayloadIO(t *testing.T) {
	c := buildTestClientWithResolvers(config.ClientConfig{
		ProtocolType:                "SOCKS5",
		SocksOptimisticConnect:      true,
		ARQWindowSize:               64,
		ARQInitialRTOSeconds:        0.2,
		ARQMaxRTOSeconds:            1,
		ARQControlInitialRTOSeconds: 0.2,
		ARQControlMaxRTOSeconds:     1,
	}, "resolver-a")
	c.syncedUploadMTU = 64

	server, localClient := net.Pipe()
	defer localClient.Close()
	done := make(chan struct{})
	go func() {
		c.handleSOCKSConnect(nil, server, "example.com", 443, SOCKS5_ATYP_DOMAIN, SOCKS5_VERSION)
		close(done)
	}()

	reply := make([]byte, 10)
	if _, err := io.ReadFull(localClient, reply); err != nil {
		t.Fatalf("read optimistic SOCKS reply: %v", err)
	}
	if reply[0] != SOCKS5_VERSION || reply[1] != SOCKS5_REPLY_SUCCESS {
		t.Fatalf("unexpected optimistic reply: %x", reply)
	}
	<-done

	var stream *Stream_client
	for _, candidate := range c.active_streams {
		stream = candidate
	}
	if stream == nil || !stream.LocalConnectReplySent {
		t.Fatal("expected optimistic stream and local acknowledgement marker")
	}

	writeDone := make(chan error, 1)
	go func() {
		_, err := localClient.Write([]byte("early payload"))
		writeDone <- err
	}()
	select {
	case err := <-writeDone:
		t.Fatalf("payload was read before remote SOCKS confirmation: %v", err)
	case <-timeAfterForTest():
	}

	if err := c.HandleSocksConnected(VpnProto.Packet{StreamID: stream.StreamID}); err != nil {
		t.Fatalf("HandleSocksConnected: %v", err)
	}
	select {
	case err := <-writeDone:
		if err != nil {
			t.Fatalf("payload write after remote confirmation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("payload reader did not start after remote SOCKS confirmation")
	}

	if arqObj, err := c.getStreamARQ(stream.StreamID); err == nil {
		arqObj.Close("test complete", arq.CloseOptions{Force: true})
	}
}

func timeAfterForTest() <-chan time.Time {
	return time.After(75 * time.Millisecond)
}
