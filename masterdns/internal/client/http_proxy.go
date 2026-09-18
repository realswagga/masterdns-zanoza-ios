package client

import (
	"bufio"
	"context"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HandleHTTPConnect accepts an RFC 7231 CONNECT request and maps it onto the
// same reliable MasterDNS stream used by the SOCKS listener. Supporting a
// second local protocol is useful for iOS consumer VPNs whose SOCKS outbound
// has an overly short handshake deadline.
func (c *Client) HandleHTTPConnect(ctx context.Context, conn net.Conn) {
	if conn == nil {
		return
	}
	_ = conn.SetDeadline(time.Now().Add(c.localHandshakeTimeout()))
	defer func() { _ = conn.SetDeadline(time.Time{}) }()

	reader := bufio.NewReaderSize(conn, 16*1024)
	request, err := http.ReadRequest(reader)
	if err != nil {
		_ = writeHTTPProxyError(conn, http.StatusBadRequest)
		_ = conn.Close()
		return
	}
	if request.Body != nil {
		defer request.Body.Close()
	}
	if request.Method != http.MethodConnect {
		_ = writeHTTPProxyError(conn, http.StatusMethodNotAllowed)
		_ = conn.Close()
		return
	}
	if c.cfg.SOCKS5Auth && !c.validHTTPProxyAuthorization(request.Header.Get("Proxy-Authorization")) {
		_, _ = fmt.Fprint(conn, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Zanoza\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		_ = conn.Close()
		return
	}

	target := request.Host
	if target == "" && request.URL != nil {
		target = request.URL.Host
	}
	host, portText, err := net.SplitHostPort(target)
	if err != nil {
		// CONNECT authority may omit the port. HTTPS is the only safe default.
		host = strings.Trim(target, "[]")
		portText = "443"
	}
	portValue, err := strconv.Atoi(portText)
	if err != nil || portValue < 1 || portValue > 65535 || strings.TrimSpace(host) == "" {
		_ = writeHTTPProxyError(conn, http.StatusBadRequest)
		_ = conn.Close()
		return
	}

	atyp := byte(SOCKS5_ATYP_DOMAIN)
	if parsed := net.ParseIP(host); parsed != nil {
		if parsed.To4() != nil {
			atyp = SOCKS5_ATYP_IPV4
		} else {
			atyp = SOCKS5_ATYP_IPV6
		}
	}
	// ReadRequest may already have buffered bytes belonging to the tunneled
	// protocol (TLS clients commonly send immediately after a fast 200). Keep
	// that reader in front of the socket so no early payload is discarded.
	c.handleSOCKSConnect(ctx, &bufferedProxyConn{Conn: conn, reader: reader}, host, uint16(portValue), atyp, LOCAL_PROXY_HTTP)
}

type bufferedProxyConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedProxyConn) Read(p []byte) (int, error) {
	if c.reader == nil {
		return c.Conn.Read(p)
	}
	return c.reader.Read(p)
}

func (c *Client) validHTTPProxyAuthorization(value string) bool {
	const prefix = "basic "
	trimmed := strings.TrimSpace(value)
	if len(trimmed) <= len(prefix) || strings.ToLower(trimmed[:len(prefix)]) != prefix {
		return false
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(trimmed[len(prefix):]))
	if err != nil {
		return false
	}
	return string(raw) == c.cfg.SOCKS5User+":"+c.cfg.SOCKS5Pass
}

func writeHTTPProxyError(conn net.Conn, status int) error {
	text := http.StatusText(status)
	if text == "" {
		text = "Proxy Error"
	}
	_, err := fmt.Fprintf(conn, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status, text)
	return err
}
