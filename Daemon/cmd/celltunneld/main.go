// Package main provides the Cell Tunnel daemon command-line entrypoint.
package main

import (
	"celltunnel/daemon/internal/tunnel"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
)

type daemonCommand string

const (
	commandStart  daemonCommand = "start"
	commandStop   daemonCommand = "stop"
	commandStatus daemonCommand = "status"
	commandCheck  daemonCommand = "check"
)

var (
	errMissingCommand = errors.New("missing command")
	errUnknownCommand = errors.New("unknown command")
)

func main() {
	configureLogging()
	slog.Info("celltunneld process started")
	exitCode := run(os.Args[1:])
	slog.Info("celltunneld process completed")
	if exitCode != 0 {
		os.Exit(exitCode)
	}
}

func configureLogging() {
	handler := slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelDebug,
	})
	slog.SetDefault(slog.New(handler).With("service", "celltunneld"))
	slog.Info("celltunneld logging configured")
}

func run(arguments []string) int {
	logger := slog.Default().With("boundary", "command-dispatch")
	logger.Info("celltunneld command dispatch started", "argument_count", len(arguments))

	if len(arguments) < 1 {
		logger.Error("celltunneld command missing", "err", errMissingCommand)
		printUsage()
		return 2
	}

	command, ok := parseCommand(arguments[0])
	if !ok {
		logger.Error("celltunneld command unknown", "err", errUnknownCommand, "command", arguments[0])
		printUsage()
		return 2
	}

	switch command {
	case commandStart:
		return runStart(arguments[1:])
	case commandStop:
		return runStop(arguments[1:])
	case commandStatus:
		runStatus()
	case commandCheck:
		return runCheck()
	default:
		logger.Error("celltunneld command dispatch fell through", "err", errUnknownCommand, "command", command)
		return 2
	}

	logger.Info("celltunneld command dispatch completed", "command", string(command))
	return 0
}

func parseCommand(rawCommand string) (daemonCommand, bool) {
	command := daemonCommand(rawCommand)
	switch command {
	case commandStart, commandStop, commandStatus, commandCheck:
		return command, true
	default:
		return "", false
	}
}

func runStart(arguments []string) int {
	logger := slog.Default().With("command", string(commandStart))
	logger.Info("celltunneld start command parsing", "argument_count", len(arguments))

	flags := flag.NewFlagSet("start", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	dryRun := flags.Bool("dry-run", false, "print planned tunnel changes without mutating networking")
	if err := flags.Parse(arguments); err != nil {
		logger.Error("celltunneld start argument parse failed", "err", err)
		fmt.Fprintf(os.Stderr, "start arguments invalid: %v\n", err)
		return 2
	}

	config := tunnel.DefaultConfig()
	if *dryRun {
		logger.Info("celltunneld start dry run planning", "interface_hint", config.InterfaceNameHint)
		fmt.Println(tunnel.DescribePlan(config))
		logger.Info("celltunneld start dry run completed", "interface_hint", config.InterfaceNameHint)
		return 0
	}

	logger.Info(
		"celltunneld start applying tunnel",
		"interface_hint",
		config.InterfaceNameHint,
		"ipv4_prefix_length",
		config.IPv4PrefixLength,
		"ipv6_prefix_length",
		config.IPv6PrefixLength,
	)
	if err := tunnel.Start(config); err != nil {
		logger.Error("celltunneld start failed", "err", err, "interface_hint", config.InterfaceNameHint)
		fmt.Fprintf(os.Stderr, "start failed: %v\n", err)
		return 1
	}
	logger.Info("celltunneld start completed", "interface_hint", config.InterfaceNameHint)
	return 0
}

func runStop(arguments []string) int {
	logger := slog.Default().With("command", string(commandStop))
	logger.Info("celltunneld stop command parsing", "argument_count", len(arguments))

	flags := flag.NewFlagSet("stop", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	dryRun := flags.Bool("dry-run", false, "print planned restore changes without mutating networking")
	if err := flags.Parse(arguments); err != nil {
		logger.Error("celltunneld stop argument parse failed", "err", err)
		fmt.Fprintf(os.Stderr, "stop arguments invalid: %v\n", err)
		return 2
	}

	if *dryRun {
		logger.Info("celltunneld stop dry run completed")
		fmt.Println("stopped=false routes=not-installed dry_run=true")
		return 0
	}

	logger.Info("celltunneld stop applying restore")
	if err := tunnel.Stop(); err != nil {
		logger.Error("celltunneld stop failed", "err", err)
		fmt.Fprintf(os.Stderr, "stop failed: %v\n", err)
		return 1
	}
	logger.Info("celltunneld stop completed")
	return 0
}

func runStatus() {
	logger := slog.Default().With("command", string(commandStatus))
	logger.Info("celltunneld status requested")
	status := tunnel.Status()
	fmt.Printf(
		"running=%t routes=%s peer=%s ipv4=%s ipv6=%s\n",
		status.Running,
		status.RouteState,
		status.PeerState,
		status.IPv4Address,
		status.IPv6Address,
	)
	logger.Info("celltunneld status emitted", "running", status.Running, "routes", status.RouteState)
}

func runCheck() int {
	logger := slog.Default().With("command", string(commandCheck))
	logger.Info("celltunneld environment check requested")
	checks := tunnel.CheckEnvironment()
	for _, check := range checks {
		fmt.Printf("%s=%s\n", check.Name, check.Value)
	}

	for _, check := range checks {
		if strings.EqualFold(check.Value, "missing") {
			logger.Error("celltunneld environment check failed", "err", errors.New("missing requirement"), "check", check.Name)
			return 1
		}
	}
	logger.Info("celltunneld environment check completed", "check_count", len(checks))
	return 0
}

func printUsage() {
	slog.Default().Info("celltunneld usage emitted")
	fmt.Fprintln(os.Stderr, "usage: celltunneld <start|stop|status|check>")
}
