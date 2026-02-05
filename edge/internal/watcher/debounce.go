package watcher

import (
	"sync"
	"time"
)

// Debouncer coalesces rapid file change events within a time window.
type Debouncer struct {
	window  time.Duration
	timers  map[string]*time.Timer
	mu      sync.Mutex
	output  chan string
	stopped bool
}

// NewDebouncer creates a debouncer with the given coalescing window.
func NewDebouncer(window time.Duration) *Debouncer {
	return &Debouncer{
		window: window,
		timers: make(map[string]*time.Timer),
		output: make(chan string, 256),
	}
}

// Trigger registers a change event for the given path.
// If a previous event for the same path is still pending, it's reset.
func (d *Debouncer) Trigger(path string) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.stopped {
		return
	}

	if timer, exists := d.timers[path]; exists {
		timer.Reset(d.window)
		return
	}

	d.timers[path] = time.AfterFunc(d.window, func() {
		d.mu.Lock()
		delete(d.timers, path)
		d.mu.Unlock()

		d.output <- path
	})
}

// Output returns the channel of debounced file paths.
func (d *Debouncer) Output() <-chan string {
	return d.output
}

// Stop cancels all pending timers and closes the output channel.
func (d *Debouncer) Stop() {
	d.mu.Lock()
	defer d.mu.Unlock()

	d.stopped = true
	for path, timer := range d.timers {
		timer.Stop()
		delete(d.timers, path)
	}
	close(d.output)
}
