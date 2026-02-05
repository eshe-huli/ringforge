package client

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// Client manages a WebSocket connection to the Keyring Phoenix server.
type Client struct {
	conn     *websocket.Conn
	url      string
	token    string
	msgRef   atomic.Int64
	channels map[string]*Channel
	mu       sync.RWMutex
	done     chan struct{}
	replies  map[string]chan *PhoenixMessage
	replyMu  sync.Mutex
}

// PhoenixMessage is the wire format for Phoenix Channel messages.
type PhoenixMessage struct {
	JoinRef string          `json:"join_ref,omitempty"`
	Ref     string          `json:"ref,omitempty"`
	Topic   string          `json:"topic"`
	Event   string          `json:"event"`
	Payload json.RawMessage `json:"payload"`
}

// New creates and connects a new Client.
func New(url, token string) (*Client, error) {
	c := &Client{
		url:      url,
		token:    token,
		channels: make(map[string]*Channel),
		done:     make(chan struct{}),
		replies:  make(map[string]chan *PhoenixMessage),
	}

	if err := c.connect(); err != nil {
		return nil, err
	}

	go c.readLoop()
	go c.heartbeatLoop()

	return c, nil
}

func (c *Client) connect() error {
	header := http.Header{}
	if c.token != "" {
		header.Set("Authorization", "Bearer "+c.token)
	}

	conn, _, err := websocket.DefaultDialer.Dial(c.url, header)
	if err != nil {
		return fmt.Errorf("websocket dial %s: %w", c.url, err)
	}
	c.conn = conn
	return nil
}

// Close shuts down the client.
func (c *Client) Close() error {
	close(c.done)
	if c.conn != nil {
		return c.conn.Close()
	}
	return nil
}

// NextRef returns a unique message reference.
func (c *Client) NextRef() string {
	return fmt.Sprintf("%d", c.msgRef.Add(1))
}

// Send writes a PhoenixMessage to the WebSocket.
func (c *Client) Send(msg *PhoenixMessage) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteJSON(msg)
}

// Push sends an event on a topic and waits for a reply (with timeout).
func (c *Client) Push(topic, event string, payload interface{}, timeout time.Duration) (*PhoenixMessage, error) {
	ref := c.NextRef()

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal payload: %w", err)
	}

	replyCh := make(chan *PhoenixMessage, 1)
	c.replyMu.Lock()
	c.replies[ref] = replyCh
	c.replyMu.Unlock()

	defer func() {
		c.replyMu.Lock()
		delete(c.replies, ref)
		c.replyMu.Unlock()
	}()

	msg := &PhoenixMessage{
		Ref:     ref,
		Topic:   topic,
		Event:   event,
		Payload: payloadBytes,
	}

	if err := c.Send(msg); err != nil {
		return nil, err
	}

	select {
	case reply := <-replyCh:
		return reply, nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("push timeout after %v", timeout)
	case <-c.done:
		return nil, fmt.Errorf("client closed")
	}
}

func (c *Client) readLoop() {
	for {
		select {
		case <-c.done:
			return
		default:
		}

		var msg PhoenixMessage
		if err := c.conn.ReadJSON(&msg); err != nil {
			if websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				return
			}
			log.Printf("[keyring] read error: %v, reconnecting...", err)
			c.reconnect()
			continue
		}

		// Route reply
		if msg.Ref != "" {
			c.replyMu.Lock()
			ch, ok := c.replies[msg.Ref]
			c.replyMu.Unlock()
			if ok {
				ch <- &msg
				continue
			}
		}

		// Route to channel handler
		c.mu.RLock()
		ch, ok := c.channels[msg.Topic]
		c.mu.RUnlock()
		if ok {
			ch.handleMessage(&msg)
		}
	}
}

func (c *Client) heartbeatLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			ref := c.NextRef()
			msg := &PhoenixMessage{
				Ref:     ref,
				Topic:   "phoenix",
				Event:   "heartbeat",
				Payload: json.RawMessage(`{}`),
			}
			if err := c.Send(msg); err != nil {
				log.Printf("[keyring] heartbeat error: %v", err)
			}
		}
	}
}

func (c *Client) reconnect() {
	backoff := time.Second
	maxBackoff := 30 * time.Second

	for {
		select {
		case <-c.done:
			return
		default:
		}

		log.Printf("[keyring] reconnecting in %v...", backoff)
		time.Sleep(backoff)

		if err := c.connect(); err != nil {
			log.Printf("[keyring] reconnect failed: %v", err)
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
			continue
		}

		log.Println("[keyring] reconnected")

		// Rejoin all channels
		c.mu.RLock()
		for _, ch := range c.channels {
			if err := ch.rejoin(); err != nil {
				log.Printf("[keyring] rejoin %s failed: %v", ch.topic, err)
			}
		}
		c.mu.RUnlock()
		return
	}
}

// RegisterChannel registers a channel for message routing.
func (c *Client) RegisterChannel(ch *Channel) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.channels[ch.topic] = ch
}
