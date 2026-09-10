// Package config loads server configuration from environment variables.
package config

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Username       string
	Password       string // plain or "bcrypt:$2a$..."
	PublicURL      string
	DataDir        string
	Listen         string
	RefreshMinutes int
	LogLevel       string
}

func FromEnv() (Config, error) {
	c := Config{
		Username:       os.Getenv("CQ_USERNAME"),
		Password:       os.Getenv("CQ_PASSWORD"),
		PublicURL:      getenv("CQ_PUBLIC_URL", "http://localhost:8080"),
		DataDir:        getenv("CQ_DATA_DIR", "/data"),
		Listen:         getenv("CQ_LISTEN", ":8080"),
		RefreshMinutes: 30,
		LogLevel:       getenv("CQ_LOG_LEVEL", "info"),
	}
	if v := os.Getenv("CQ_REFRESH_MINUTES"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return c, fmt.Errorf("CQ_REFRESH_MINUTES: invalid value %q", v)
		}
		c.RefreshMinutes = n
	}
	if c.Username == "" || c.Password == "" {
		return c, errors.New("CQ_USERNAME and CQ_PASSWORD must be set")
	}
	c.PublicURL = strings.TrimRight(c.PublicURL, "/")
	return c, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
