// Package signer exposes the Apache-2.0 xhssign library to the tvOS client.
// Upstream: https://github.com/tamnd/xiaohongshu-cli (see go.mod for the pin).
package signer

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/url"
	"time"

	"github.com/tamnd/xiaohongshu-cli/pkg/xhssign"
)

// NewSession returns an anonymous browser session fingerprint as JSON.
func NewSession() (string, error) {
	var randomErr error
	random := func(n int) []byte {
		b := make([]byte, n)
		if _, err := rand.Read(b); err != nil {
			randomErr = err
		}
		return b
	}
	a1 := xhssign.GenerateA1(time.Now(), random)
	if randomErr != nil {
		return "", randomErr
	}
	data, err := json.Marshal(map[string]string{"a1": a1, "webId": xhssign.WebID(a1)})
	return string(data), err
}

// Headers signs the exact request body and URI using the supplied cookie map.
func Headers(method, uri, body, cookiesJSON string) (string, error) {
	var cookies map[string]string
	if err := json.Unmarshal([]byte(cookiesJSON), &cookies); err != nil {
		return "", err
	}
	if cookies["a1"] == "" {
		return "", errors.New("missing a1 session")
	}
	parsed, err := url.ParseRequestURI(uri)
	if err != nil {
		return "", err
	}
	params := make(map[string]string)
	for k, v := range parsed.Query() {
		if len(v) > 0 {
			params[k] = v[0]
		}
	}
	headers := xhssign.New().Sign(xhssign.Request{Method: method, URI: parsed.Path, Params: params, Body: body, A1: cookies["a1"], Cookies: cookies})
	data, err := json.Marshal(headers.Map())
	return string(data), err
}
