package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	gohttp "net/http"
	"strings"

	"github.com/majd/ipatool/v2/pkg/appstore"
	ipahttp "github.com/majd/ipatool/v2/pkg/http"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"howett.net/plist"
)

// Download authorization without transferring the package.
//
// Apple issues *fresh licence material on every authorization*: requesting the same
// app twice for the same account and version returns two different sinf blobs. The
// request carries no device identifier at all — only the Mac's guid and a literal
// serialNumber of "0" — so the licence is scoped to the Apple Account, not to a
// phone. That means the 34 MB package can be downloaded once and reused, while each
// device still gets its own authorization, which is what this call is for.
//
// The request shape mirrors ipatool's `downloadRequest`. It is duplicated here
// rather than forked into the vendored tree so third_party/ stays updatable; if
// ipatool changes that request, this must be re-checked alongside it.

type authorizeParams struct {
	Account           account `json:"account"`
	Cookies           string  `json:"cookies"`
	AppStoreID        int64   `json:"appStoreID"`
	BundleID          string  `json:"bundleID"`
	ExternalVersionID string  `json:"externalVersionID"`
}

type authorizeResult struct {
	// base64. Handed to installation_proxy as ApplicationSINF / iTunesMetadata.
	Sinf     string `json:"sinf"`
	Metadata string `json:"metadata"`
	Version  string `json:"version"`
	BundleID string `json:"bundleID"`
}

type authorizeItem struct {
	URL      string                 `plist:"URL,omitempty"`
	Sinfs    []appstore.Sinf        `plist:"sinfs,omitempty"`
	Metadata map[string]interface{} `plist:"metadata,omitempty"`
}

type authorizeResponse struct {
	FailureType     string          `plist:"failureType,omitempty"`
	CustomerMessage string          `plist:"customerMessage,omitempty"`
	Items           []authorizeItem `plist:"songList,omitempty"`
}

func handleAuthorize(params authorizeParams) (*authorizeResult, *rpcError) {
	jar, err := newSessionJar(params.Cookies)
	if err != nil {
		return nil, internalError(err)
	}
	defer jar.close()

	system := operatingsystem.New()
	macAddress, err := machine.New(machine.Args{OS: system}).MacAddress()
	if err != nil {
		return nil, internalError(err)
	}
	guid := strings.ReplaceAll(strings.ToUpper(macAddress), ":", "")

	payload := map[string]interface{}{
		"creditDisplay": "",
		"guid":          guid,
		"salableAdamId": params.AppStoreID,
		"serialNumber":  "0",
	}
	if params.ExternalVersionID != "" {
		payload["externalVersionId"] = params.ExternalVersionID
	}

	podPrefix := ""
	if params.Account.Pod != "" {
		podPrefix = "p" + params.Account.Pod + "-"
	}

	client := ipahttp.NewClient[authorizeResponse](ipahttp.Args{CookieJar: jar})
	result, err := client.Send(ipahttp.Request{
		URL: fmt.Sprintf(
			"https://%s%s%s?guid=%s",
			podPrefix,
			appstore.PrivateAppStoreAPIDomain,
			appstore.PrivateAppStoreAPIPathDownload,
			guid,
		),
		Method:         ipahttp.MethodPOST,
		ResponseFormat: ipahttp.ResponseFormatXML,
		Headers: map[string]string{
			"Content-Type": "application/x-apple-plist",
			"iCloud-DSID":  params.Account.DirectoryServicesID,
			"X-Dsid":       params.Account.DirectoryServicesID,
		},
		Payload: &ipahttp.XMLPayload{Content: payload},
	})
	if err != nil {
		return nil, internalError(err)
	}

	switch result.Data.FailureType {
	case "":
		// Success.
	case appstore.FailureTypeLicenseNotFound:
		return nil, &rpcError{
			Code:    errCodeNotPurchased,
			Message: "This Apple Account does not hold a licence for this app.",
		}
	case appstore.FailureTypePasswordTokenExpired,
		appstore.FailureTypeSignInRequired,
		appstore.FailureTypeDeviceVerificationFailed:
		return nil, &rpcError{
			Code:    errCodeSessionExpired,
			Message: "Your App Store session expired. Sign in again.",
		}
	default:
		message := result.Data.CustomerMessage
		if message == "" {
			message = "Apple declined the download authorization."
		}
		return nil, &rpcError{Code: errCodeAppleUnavailable, Message: redact(message)}
	}

	if result.StatusCode != gohttp.StatusOK || len(result.Data.Items) == 0 {
		return nil, &rpcError{
			Code:    errCodeAppleUnavailable,
			Message: "Apple returned no download authorization for this app.",
		}
	}

	item := result.Data.Items[0]
	if len(item.Sinfs) == 0 || len(item.Sinfs[0].Data) == 0 {
		return nil, &rpcError{
			Code:    errCodeLicenceRequired,
			Message: "Apple returned no licence for this app on this account.",
		}
	}

	metadata := item.Metadata
	if metadata == nil {
		metadata = map[string]interface{}{}
	}
	metadata["apple-id"] = params.Account.Email
	metadata["userName"] = params.Account.Email

	encoded, err := plist.Marshal(metadata, plist.BinaryFormat)
	if err != nil {
		return nil, internalError(errors.New("could not encode store metadata"))
	}

	version := ""
	if value, ok := metadata["bundleShortVersionString"]; ok {
		version = fmt.Sprintf("%v", value)
	}
	bundleID := params.BundleID
	if value, ok := metadata["softwareVersionBundleId"]; ok {
		bundleID = fmt.Sprintf("%v", value)
	}

	return &authorizeResult{
		Sinf:     base64.StdEncoding.EncodeToString(item.Sinfs[0].Data),
		Metadata: base64.StdEncoding.EncodeToString(encoded),
		Version:  version,
		BundleID: bundleID,
	}, nil
}
