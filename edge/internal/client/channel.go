package client

import (
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"
)

// Channel represents a Phoenix Channel subscription.
type Channel struct {
	client   *Client
	topic    string
	joinRef  string
	params   map[string]interface{}
	handlers map[string][]MessageHandler
	mu       sync.RWMutex
	joined   bool
}

// MessageHandler processes incoming channel messages.
type MessageHandler func(payload json.RawMessage)

// NewChannel creates a channel for the given topic.
func NewChannel(c *Client, topic string, params map[string]interface{}) *Channel {
	ch := &Channel{
		client:   c,
		topic:    topic,
		params:   params,
		handlers: make(map[string][]MessageHandler),
	}
	c.RegisterChannel(ch)
	return ch
}

// Join sends a phx_join message and waits for a reply.
func (ch *Channel) Join(timeout time.Duration) error {
	ref := ch.client.NextRef()
	ch.joinRef = ref

	payload := ch.params
	if payload == nil {
		payload = map[string]interface{}{}
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal join params: %w", err)
	}

	replyCh := make(chan *PhoenixMessage, 1)
	ch.client.replyMu.Lock()
	ch.client.replies[ref] = replyCh
	ch.client.replyMu.Unlock()

	defer func() {
		ch.client.replyMu.Lock()
		delete(ch.client.replies, ref)
		ch.client.replyMu.Unlock()
	}()

	msg := &PhoenixMessage{
		JoinRef: ref,
		Ref:     ref,
		Topic:   ch.topic,
		Event:   "phx_join",
		Payload: payloadBytes,
	}

	if err := ch.client.Send(msg); err != nil {
		return fmt.Errorf("send join: %w", err)
	}

	select {
	case reply := <-replyCh:
		var resp struct {
			Status   string          `json:"status"`
			Response json.RawMessage `json:"response"`
		}
		if err := json.Unmarshal(reply.Payload, &resp); err != nil {
			return fmt.Errorf("unmarshal join reply: %w", err)
		}
		if resp.Status != "ok" {
			return fmt.Errorf("join rejected: %s %s", resp.Status, string(resp.Response))
		}
		ch.joined = true
		log.Printf("[keyring] joined %s", ch.topic)
		return nil
	case <-time.After(timeout):
		return fmt.Errorf("join timeout after %v", timeout)
	}
}

// Leave sends a phx_leave message.
func (ch *Channel) Leave() error {
	msg := &PhoenixMessage{
		JoinRef: ch.joinRef,
		Ref:     ch.client.NextRef(),
		Topic:   ch.topic,
		Event:   "phx_leave",
		Payload: json.RawMessage(`{}`),
	}
	ch.joined = false
	return ch.client.Send(msg)
}

// Push sends an event on this channel and waits for a reply.
// Includes the join_ref so the Phoenix server routes the message
// to the correct channel process.
func (ch *Channel) Push(event string, payload interface{}, timeout time.Duration) (*PhoenixMessage, error) {
	if !ch.joined {
		return nil, fmt.Errorf("channel %s not joined", ch.topic)
	}
	return ch.client.PushWithJoinRef(ch.topic, ch.joinRef, event, payload, timeout)
}

// On registers a handler for a specific event.
func (ch *Channel) On(event string, handler MessageHandler) {
	ch.mu.Lock()
	defer ch.mu.Unlock()
	ch.handlers[event] = append(ch.handlers[event], handler)
}

// handleMessage dispatches incoming messages to registered handlers.
func (ch *Channel) handleMessage(msg *PhoenixMessage) {
	ch.mu.RLock()
	handlers, ok := ch.handlers[msg.Event]
	ch.mu.RUnlock()

	if !ok {
		return
	}

	for _, h := range handlers {
		go h(msg.Payload)
	}
}

// rejoin re-joins the channel after reconnection.
func (ch *Channel) rejoin() error {
	ch.joined = false
	return ch.Join(10 * time.Second)
}
