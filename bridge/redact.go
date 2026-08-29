package main

import (
	"encoding/json"
	"regexp"
	"strings"
)

// Sensitive values must never reach stderr or an error message shown in the UI.
// ipatool's errors can embed the request or response that failed, which for the
// authenticate call includes the password and for later calls includes the token.
var sensitivePatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)("?(?:password|passwordToken|dsPersonId|X-Token|X-Dsid|iCloud-DSID|X-Apple-ActionSignature|Set-Cookie|Cookie|sinf|guid|machineID)"?\s*[:=]\s*)("?)([^",}\s]+)("?)`),
	regexp.MustCompile(`(?i)(<key>(?:password|passwordToken|dsPersonId)</key>\s*<string>)([^<]*)(</string>)`),
}

// redact scrubs a string before it is logged or returned to the app.
func redact(input string) string {
	output := input
	for _, pattern := range sensitivePatterns {
		output = pattern.ReplaceAllString(output, "${1}${2}[redacted]${4}")
	}
	return output
}

// marshalJSON is the only JSON encoder used for values that may hold credentials,
// so there is one place to audit.
func marshalJSON(value interface{}) ([]byte, error) {
	return json.Marshal(value)
}

// rawJSON defers decoding of a request's params until the method is known.
type rawJSON = json.RawMessage

// plistStrings extracts string values for the given keys from an XML or binary
// plist without pulling in a full parser. Only used for Info.plist facts that are
// already known to be plain strings.
func plistStrings(data []byte, keys ...string) (string, string) {
	results := make([]string, len(keys))
	text := string(data)
	for index, key := range keys {
		results[index] = plistStringValue(text, key)
	}
	if len(results) < 2 {
		return results[0], ""
	}
	return results[0], results[1]
}

func plistStringValue(document string, key string) string {
	// XML form: <key>K</key><string>V</string>
	marker := "<key>" + key + "</key>"
	if index := strings.Index(document, marker); index >= 0 {
		rest := document[index+len(marker):]
		if open := strings.Index(rest, "<string>"); open >= 0 {
			rest = rest[open+len("<string>"):]
			if close := strings.Index(rest, "</string>"); close >= 0 {
				return rest[:close]
			}
		}
		return ""
	}
	// Binary form: fall back to scanning for the key followed by a printable
	// value. Info.plist inside an IPA is usually binary, and this is only used
	// for display fields with a safe empty fallback.
	if index := strings.Index(document, key); index >= 0 {
		rest := document[index+len(key):]
		return firstPrintableRun(rest)
	}
	return ""
}

func firstPrintableRun(input string) string {
	start := -1
	for index := 0; index < len(input) && index < 512; index++ {
		char := input[index]
		printable := char >= 0x20 && char < 0x7f
		if printable && start < 0 {
			start = index
		}
		if !printable && start >= 0 {
			candidate := input[start:index]
			if len(candidate) >= 3 {
				return candidate
			}
			start = -1
		}
	}
	return ""
}
