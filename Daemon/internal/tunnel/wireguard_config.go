package tunnel

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
)

type wireGuardSection string

const (
	wireGuardSectionNone      wireGuardSection = ""
	wireGuardSectionInterface wireGuardSection = "Interface"
	wireGuardSectionPeer      wireGuardSection = "Peer"
)

type wireGuardField string

const (
	wireGuardFieldAddress             wireGuardField = "Address"
	wireGuardFieldAllowedIPs          wireGuardField = "AllowedIPs"
	wireGuardFieldEndpoint            wireGuardField = "Endpoint"
	wireGuardFieldListenPort          wireGuardField = "ListenPort"
	wireGuardFieldPersistentKeepalive wireGuardField = "PersistentKeepalive"
	wireGuardFieldPresharedKey        wireGuardField = "PresharedKey"
	wireGuardFieldPrivateKey          wireGuardField = "PrivateKey"
	wireGuardFieldPublicKey           wireGuardField = "PublicKey"
)

// RelayAddressFamily identifies the endpoint address family carried in relay frames.
type RelayAddressFamily uint8

const (
	// RelayAddressFamilyIPv4 marks an IPv4 relay endpoint.
	RelayAddressFamilyIPv4 RelayAddressFamily = 4
	// RelayAddressFamilyIPv6 marks an IPv6 relay endpoint.
	RelayAddressFamilyIPv6 RelayAddressFamily = 6
)

// RelayEndpoint describes the hosted WireGuard server endpoint sent to the iPhone app.
type RelayEndpoint struct {
	AddressFamily RelayAddressFamily `json:"addressFamily"`
	Host          string             `json:"host"`
	Port          uint16             `json:"port"`
}

// AddressPort renders the endpoint in host:port form for WireGuard configuration.
func (endpoint RelayEndpoint) AddressPort() string {
	return net.JoinHostPort(endpoint.Host, strconv.Itoa(int(endpoint.Port)))
}

// WireGuardKey stores a WireGuard key in UAPI hex form.
type WireGuardKey struct {
	hexValue string
}

// HexValue returns the UAPI hex form of a WireGuard key.
func (key WireGuardKey) HexValue() string {
	return key.hexValue
}

// WireGuardInterfaceConfig describes the local interface section of a WireGuard config file.
type WireGuardInterfaceConfig struct {
	PrivateKey    WireGuardKey
	Addresses     []netip.Prefix
	ListenPort    uint16
	HasListenPort bool
}

// WireGuardPeerConfig describes the single hosted WireGuard server peer used by the MVP.
type WireGuardPeerConfig struct {
	PublicKey                  WireGuardKey
	PresharedKey               WireGuardKey
	HasPresharedKey            bool
	Endpoint                   RelayEndpoint
	AllowedIPs                 []netip.Prefix
	PersistentKeepaliveSeconds uint16
	HasPersistentKeepalive     bool
}

// WireGuardConfig is the typed daemon view of a WireGuard client config file.
type WireGuardConfig struct {
	Interface WireGuardInterfaceConfig
	Peer      WireGuardPeerConfig
}

var (
	errWireGuardConfigMissingInterface = errors.New("wireguard config missing interface section")
	errWireGuardConfigMissingPeer      = errors.New("wireguard config missing peer section")
	errWireGuardConfigMissingEndpoint  = errors.New("wireguard config missing peer endpoint")
)

// LoadWireGuardConfig reads and parses a WireGuard client config file.
func LoadWireGuardConfig(path string) (WireGuardConfig, error) {
	logger.Info("loading wireguard config", "path_configured", path != "")
	file, err := os.Open(path)
	if err != nil {
		logger.Error("wireguard config open failed", "err", err, "path_configured", path != "")
		return WireGuardConfig{}, fmt.Errorf("open wireguard config: %w", err)
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			logger.Error("wireguard config close failed", "err", closeErr)
		}
	}()

	config, err := ParseWireGuardConfig(file)
	if err != nil {
		logger.Error("wireguard config parse failed", "err", err)
		return WireGuardConfig{}, err
	}
	logger.Info(
		"wireguard config loaded",
		"address_count",
		len(config.Interface.Addresses),
		"allowed_ip_count",
		len(config.Peer.AllowedIPs),
		"endpoint_family",
		config.Peer.Endpoint.AddressFamily,
	)
	return config, nil
}

// ParseWireGuardConfig parses a WireGuard client config from reader.
func ParseWireGuardConfig(reader io.Reader) (WireGuardConfig, error) {
	scanner := bufio.NewScanner(reader)
	config := WireGuardConfig{}
	section := wireGuardSectionNone
	hasInterface := false
	hasPeer := false
	hasEndpoint := false

	for scanner.Scan() {
		line := strippedWireGuardLine(scanner.Text())
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = wireGuardSection(strings.TrimSuffix(strings.TrimPrefix(line, "["), "]"))
			if section == wireGuardSectionInterface {
				hasInterface = true
			}
			if section == wireGuardSectionPeer {
				hasPeer = true
			}
			continue
		}

		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return WireGuardConfig{}, fmt.Errorf("invalid wireguard config line: %s", line)
		}

		field := wireGuardField(strings.TrimSpace(key))
		trimmedValue := strings.TrimSpace(value)
		if err := applyWireGuardField(&config, section, field, trimmedValue); err != nil {
			return WireGuardConfig{}, err
		}
		if section == wireGuardSectionPeer && field == wireGuardFieldEndpoint {
			hasEndpoint = true
		}
	}

	if err := scanner.Err(); err != nil {
		logger.Error("wireguard config scan failed", "err", err)
		return WireGuardConfig{}, fmt.Errorf("scan wireguard config: %w", err)
	}
	if !hasInterface {
		return WireGuardConfig{}, errWireGuardConfigMissingInterface
	}
	if !hasPeer {
		return WireGuardConfig{}, errWireGuardConfigMissingPeer
	}
	if !hasEndpoint {
		return WireGuardConfig{}, errWireGuardConfigMissingEndpoint
	}
	return config, nil
}

func strippedWireGuardLine(rawLine string) string {
	line := strings.TrimSpace(rawLine)
	if beforeComment, _, found := strings.Cut(line, "#"); found {
		line = strings.TrimSpace(beforeComment)
	}
	return line
}

func applyWireGuardField(
	config *WireGuardConfig,
	section wireGuardSection,
	field wireGuardField,
	value string,
) error {
	switch section {
	case wireGuardSectionInterface:
		return applyWireGuardInterfaceField(config, field, value)
	case wireGuardSectionPeer:
		return applyWireGuardPeerField(config, field, value)
	case wireGuardSectionNone:
		return fmt.Errorf("wireguard config field outside supported section: %s", field)
	default:
		return fmt.Errorf("wireguard config field outside supported section: %s", field)
	}
}

func applyWireGuardInterfaceField(config *WireGuardConfig, field wireGuardField, value string) error {
	switch field {
	case wireGuardFieldPrivateKey:
		key, err := unmarshalWireGuardKey(value)
		if err != nil {
			return err
		}
		config.Interface.PrivateKey = key
	case wireGuardFieldAddress:
		prefixes, err := parsePrefixList(value)
		if err != nil {
			return err
		}
		config.Interface.Addresses = append(config.Interface.Addresses, prefixes...)
	case wireGuardFieldListenPort:
		port, err := parsePort(value)
		if err != nil {
			return err
		}
		config.Interface.ListenPort = port
		config.Interface.HasListenPort = true
	case wireGuardFieldAllowedIPs,
		wireGuardFieldEndpoint,
		wireGuardFieldPersistentKeepalive,
		wireGuardFieldPresharedKey,
		wireGuardFieldPublicKey:
		logger.Debug("wireguard interface field ignored", "field", string(field))
	default:
		logger.Debug("wireguard interface field ignored", "field", string(field))
	}
	return nil
}

func applyWireGuardPeerField(config *WireGuardConfig, field wireGuardField, value string) error {
	switch field {
	case wireGuardFieldPublicKey:
		key, err := unmarshalWireGuardKey(value)
		if err != nil {
			return err
		}
		config.Peer.PublicKey = key
	case wireGuardFieldPresharedKey:
		key, err := unmarshalWireGuardKey(value)
		if err != nil {
			return err
		}
		config.Peer.PresharedKey = key
		config.Peer.HasPresharedKey = true
	case wireGuardFieldEndpoint:
		endpoint, err := ParseWireGuardEndpoint(value)
		if err != nil {
			return err
		}
		config.Peer.Endpoint = endpoint
	case wireGuardFieldAllowedIPs:
		prefixes, err := parsePrefixList(value)
		if err != nil {
			return err
		}
		config.Peer.AllowedIPs = append(config.Peer.AllowedIPs, prefixes...)
	case wireGuardFieldPersistentKeepalive:
		keepalive, err := parsePersistentKeepalive(value)
		if err != nil {
			return err
		}
		config.Peer.PersistentKeepaliveSeconds = keepalive
		config.Peer.HasPersistentKeepalive = true
	case wireGuardFieldAddress,
		wireGuardFieldListenPort,
		wireGuardFieldPrivateKey:
		logger.Debug("wireguard peer field ignored", "field", string(field))
	default:
		logger.Debug("wireguard peer field ignored", "field", string(field))
	}
	return nil
}

func unmarshalWireGuardKey(value string) (WireGuardKey, error) {
	decodedKey, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		logger.Error("wireguard key decode failed", "err", err)
		return WireGuardKey{}, fmt.Errorf("decode wireguard key: %w", err)
	}
	if len(decodedKey) != 32 {
		return WireGuardKey{}, fmt.Errorf("wireguard key length invalid: %d", len(decodedKey))
	}
	return WireGuardKey{hexValue: hex.EncodeToString(decodedKey)}, nil
}

func parsePrefixList(value string) ([]netip.Prefix, error) {
	rawPrefixes := strings.Split(value, ",")
	prefixes := make([]netip.Prefix, 0, len(rawPrefixes))
	for _, rawPrefix := range rawPrefixes {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(rawPrefix))
		if err != nil {
			logger.Error("wireguard prefix parse failed", "err", err)
			return nil, fmt.Errorf("parse wireguard prefix: %w", err)
		}
		prefixes = append(prefixes, prefix)
	}
	return prefixes, nil
}

// ParseWireGuardEndpoint parses a WireGuard endpoint in host:port form.
func ParseWireGuardEndpoint(value string) (RelayEndpoint, error) {
	host, rawPort, err := net.SplitHostPort(value)
	if err != nil {
		logger.Error("wireguard endpoint split failed", "err", err)
		return RelayEndpoint{}, fmt.Errorf("split wireguard endpoint: %w", err)
	}
	port, err := parsePort(rawPort)
	if err != nil {
		return RelayEndpoint{}, err
	}

	addressFamily := RelayAddressFamilyIPv4
	address, err := netip.ParseAddr(host)
	if err == nil && address.Is6() {
		addressFamily = RelayAddressFamilyIPv6
	}

	return RelayEndpoint{
		AddressFamily: addressFamily,
		Host:          host,
		Port:          port,
	}, nil
}

func parsePort(value string) (uint16, error) {
	port, err := strconv.ParseUint(value, 10, 16)
	if err != nil {
		logger.Error("port parse failed", "err", err)
		return 0, fmt.Errorf("parse port: %w", err)
	}
	if port == 0 {
		return 0, errors.New("port must be greater than zero")
	}
	return uint16(port), nil
}

func parsePersistentKeepalive(value string) (uint16, error) {
	keepalive, err := strconv.ParseUint(value, 10, 16)
	if err != nil {
		logger.Error("persistent keepalive parse failed", "err", err)
		return 0, fmt.Errorf("parse persistent keepalive: %w", err)
	}
	return uint16(keepalive), nil
}

// UAPIConfig renders the parsed config for wireguard-go's IPC set operation.
func (config WireGuardConfig) UAPIConfig() string {
	var builder strings.Builder
	builder.WriteString("private_key=")
	builder.WriteString(config.Interface.PrivateKey.HexValue())
	builder.WriteByte('\n')
	if config.Interface.HasListenPort {
		builder.WriteString("listen_port=")
		builder.WriteString(strconv.Itoa(int(config.Interface.ListenPort)))
		builder.WriteByte('\n')
	}
	builder.WriteString("replace_peers=true\n")
	builder.WriteString("public_key=")
	builder.WriteString(config.Peer.PublicKey.HexValue())
	builder.WriteByte('\n')
	if config.Peer.HasPresharedKey {
		builder.WriteString("preshared_key=")
		builder.WriteString(config.Peer.PresharedKey.HexValue())
		builder.WriteByte('\n')
	}
	builder.WriteString("endpoint=")
	builder.WriteString(config.Peer.Endpoint.AddressPort())
	builder.WriteByte('\n')
	builder.WriteString("replace_allowed_ips=true\n")
	for _, allowedIP := range config.Peer.AllowedIPs {
		builder.WriteString("allowed_ip=")
		builder.WriteString(allowedIP.String())
		builder.WriteByte('\n')
	}
	if config.Peer.HasPersistentKeepalive {
		builder.WriteString("persistent_keepalive_interval=")
		builder.WriteString(strconv.Itoa(int(config.Peer.PersistentKeepaliveSeconds)))
		builder.WriteByte('\n')
	}
	builder.WriteByte('\n')
	return builder.String()
}
