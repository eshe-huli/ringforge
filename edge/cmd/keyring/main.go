package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var (
	version   = "0.1.0"
	cfgFile   string
	serverURL string
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "keyring",
		Short: "Keyring — encrypted sync agent",
		Long: `Keyring is a local agent that watches files, encrypts changes,
and syncs them to the Keyring cluster via Phoenix Channels over WebSocket.`,
		Version: version,
	}

	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default: ~/.keyring/config.toml)")
	rootCmd.PersistentFlags().StringVar(&serverURL, "server", "ws://localhost:4000/socket/websocket", "Keyring server WebSocket URL")

	rootCmd.AddCommand(initCmd())
	rootCmd.AddCommand(statusCmd())
	rootCmd.AddCommand(connectCmd())
	rootCmd.AddCommand(syncCmd())
	rootCmd.AddCommand(watchCmd())
	rootCmd.AddCommand(putCmd())
	rootCmd.AddCommand(getCmd())

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func initCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "init [directory]",
		Short: "Initialize a directory for Keyring sync",
		Long:  "Sets up a .keyring directory, generates keypair, and creates the local SQLite store.",
		Args:  cobra.MaximumNArgs(1),
		RunE:  runInit,
	}
	return cmd
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show sync status and pending changes",
		RunE:  runStatus,
	}
}

func connectCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "connect",
		Short: "Connect to the Keyring cluster",
		Long:  "Establishes a WebSocket connection and joins the sync channel.",
		RunE:  runConnect,
	}
	cmd.Flags().String("token", "", "authentication token")
	return cmd
}

func syncCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sync",
		Short: "Run a one-shot sync (upload pending, download new)",
		RunE:  runSync,
	}
}

func watchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "watch [directories...]",
		Short: "Watch directories for changes and sync continuously",
		Long:  "Watches the specified directories (or configured defaults) for file changes, computes BLAKE3 hashes, and syncs via WebSocket.",
		RunE:  runWatch,
	}
	cmd.Flags().Duration("debounce", 500_000_000, "debounce window for file changes")
	return cmd
}

func putCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "put <key> <file>",
		Short: "Upload a single file to the Keyring cluster",
		Args:  cobra.ExactArgs(2),
		RunE:  runPut,
	}
}

func getCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <key> [output]",
		Short: "Download a file from the Keyring cluster",
		Args:  cobra.RangeArgs(1, 2),
		RunE:  runGet,
	}
	cmd.Flags().BoolP("stdout", "o", false, "write to stdout instead of file")
	return cmd
}

// ── Command Implementations ──────────────────────────────────────────

func runInit(cmd *cobra.Command, args []string) error {
	dir := "."
	if len(args) > 0 {
		dir = args[0]
	}

	keyringDir := dir + "/.keyring"
	if err := os.MkdirAll(keyringDir, 0700); err != nil {
		return fmt.Errorf("create .keyring dir: %w", err)
	}

	// Generate Ed25519 keypair
	pubKey, privKey, err := generateKeypair()
	if err != nil {
		return fmt.Errorf("generate keypair: %w", err)
	}

	if err := os.WriteFile(keyringDir+"/id_ed25519", privKey, 0600); err != nil {
		return fmt.Errorf("write private key: %w", err)
	}
	if err := os.WriteFile(keyringDir+"/id_ed25519.pub", pubKey, 0644); err != nil {
		return fmt.Errorf("write public key: %w", err)
	}

	// Initialize SQLite store
	store, err := openStore(keyringDir + "/keyring.db")
	if err != nil {
		return fmt.Errorf("init store: %w", err)
	}
	defer store.Close()

	fmt.Printf("✓ Initialized Keyring in %s\n", dir)
	fmt.Printf("  Public key: %s/id_ed25519.pub\n", keyringDir)
	fmt.Printf("  Database:   %s/keyring.db\n", keyringDir)
	return nil
}

func runStatus(cmd *cobra.Command, args []string) error {
	store, err := openStore(".keyring/keyring.db")
	if err != nil {
		return fmt.Errorf("open store (have you run 'keyring init'?): %w", err)
	}
	defer store.Close()

	pending, err := store.PendingCount()
	if err != nil {
		return fmt.Errorf("count pending: %w", err)
	}

	fmt.Printf("Keyring Status\n")
	fmt.Printf("  Pending changes: %d\n", pending)
	fmt.Printf("  Server:          %s\n", serverURL)
	return nil
}

func runConnect(cmd *cobra.Command, args []string) error {
	token, _ := cmd.Flags().GetString("token")
	if token == "" {
		// Try reading from .keyring/token
		data, err := os.ReadFile(".keyring/token")
		if err != nil {
			return fmt.Errorf("no token provided and .keyring/token not found")
		}
		token = string(data)
	}

	client, err := newClient(serverURL, token)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Close()

	fmt.Println("✓ Connected to Keyring cluster")
	fmt.Println("  Press Ctrl+C to disconnect")

	// Block until interrupted
	select {}
}

func runSync(cmd *cobra.Command, args []string) error {
	store, err := openStore(".keyring/keyring.db")
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer store.Close()

	token, _ := os.ReadFile(".keyring/token")
	client, err := newClient(serverURL, string(token))
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Close()

	// Upload pending changes
	uploaded, err := uploadPending(client, store)
	if err != nil {
		return fmt.Errorf("upload: %w", err)
	}

	// Download new changes
	downloaded, err := downloadNew(client, store)
	if err != nil {
		return fmt.Errorf("download: %w", err)
	}

	fmt.Printf("✓ Sync complete: %d uploaded, %d downloaded\n", uploaded, downloaded)
	return nil
}

func runWatch(cmd *cobra.Command, args []string) error {
	debounce, _ := cmd.Flags().GetDuration("debounce")

	dirs := args
	if len(dirs) == 0 {
		dirs = []string{"."}
	}

	store, err := openStore(".keyring/keyring.db")
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	defer store.Close()

	fmt.Printf("👁 Watching %v (debounce: %v)\n", dirs, debounce)

	return watchDirs(dirs, debounce, store)
}

func runPut(cmd *cobra.Command, args []string) error {
	key := args[0]
	filePath := args[1]

	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("read file: %w", err)
	}

	hash := computeBlake3(data)

	token, _ := os.ReadFile(".keyring/token")
	client, err := newClient(serverURL, string(token))
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Close()

	if err := uploadFile(client, key, data, hash); err != nil {
		return fmt.Errorf("upload: %w", err)
	}

	fmt.Printf("✓ Uploaded %s → %s (blake3:%x)\n", filePath, key, hash[:8])
	return nil
}

func runGet(cmd *cobra.Command, args []string) error {
	key := args[0]
	toStdout, _ := cmd.Flags().GetBool("stdout")

	token, _ := os.ReadFile(".keyring/token")
	client, err := newClient(serverURL, string(token))
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer client.Close()

	data, err := downloadFile(client, key)
	if err != nil {
		return fmt.Errorf("download: %w", err)
	}

	if toStdout {
		os.Stdout.Write(data)
		return nil
	}

	output := key
	if len(args) > 1 {
		output = args[1]
	}

	if err := os.WriteFile(output, data, 0644); err != nil {
		return fmt.Errorf("write file: %w", err)
	}

	fmt.Printf("✓ Downloaded %s → %s (%d bytes)\n", key, output, len(data))
	return nil
}
