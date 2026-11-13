package signer

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSessionAndSignedHeaders(t *testing.T) {
	raw, err := NewSession()
	if err != nil {
		t.Fatal(err)
	}
	var cookies map[string]string
	if err := json.Unmarshal([]byte(raw), &cookies); err != nil {
		t.Fatal(err)
	}
	if cookies["a1"] == "" || cookies["webId"] == "" {
		t.Fatal("missing session identifiers")
	}
	result, err := Headers("POST", "/api/qrcode/userinfo", `{"code":"example","qrId":"example"}`, raw)
	if err != nil {
		t.Fatal(err)
	}
	var headers map[string]string
	if err := json.Unmarshal([]byte(result), &headers); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(headers["x-s"], "XYW_") || headers["x-t"] == "" || headers["x-s-common"] == "" {
		t.Fatal("missing signing headers")
	}
}

func TestRejectsMissingSession(t *testing.T) {
	if _, err := Headers("GET", "/test", "", `{}`); err == nil {
		t.Fatal("expected missing session error")
	}
}

func TestQueryURIEscapesSensitiveValuesAndSignsSameURI(t *testing.T) {
	uri, err := QueryURI("/api/test", `{"token":"a+b/c= d","cursor":""}`)
	if err != nil {
		t.Fatal(err)
	}
	if uri != "/api/test?cursor=&token=a%2Bb%2Fc%3D+d" {
		t.Fatalf("unexpected URI: %s", uri)
	}
	if _, err := Headers("GET", uri, "", `{"a1":"test","webId":"test"}`); err != nil {
		t.Fatal(err)
	}
}
