package main

// Discovery of Designated Resolvers (RFC 9462). macOS asks its resolver —
// here, us at 127.0.0.1 — for _dns.resolver.arpa SVCB; forwarded upstream,
// Cloudflare and Control D answer with their own encrypted endpoints, and
// mDNSResponder then contacts those directly. Verification should fail (no
// certificate can cover 127.0.0.1), but if macOS ever used them it would bypass
// the engine, and for Control D land on its free resolver without the user's
// Resolver ID. So resolver.arpa never leaves the machine: RFC 9462 §6.4 says a
// resolver without designated resolvers answers NODATA, which is what we are.

import (
	"context"
	"strings"

	"github.com/AdguardTeam/dnsproxy/proxy"
	"github.com/miekg/dns"
)

const resolverARPA = "resolver.arpa."

// ddrNegativeTTL bounds how long the NODATA is cached (RFC 2308: the SOA's
// TTL and MINIMUM). Short enough that nothing sticks, long enough that
// mDNSResponder doesn't re-ask on every lookup.
const ddrNegativeTTL = 60

// isResolverARPA reports whether name is resolver.arpa or anything under it,
// in any letter case, with or without the trailing dot.
func isResolverARPA(name string) bool {
	n := strings.ToLower(dns.Fqdn(name))
	return n == resolverARPA || strings.HasSuffix(n, "."+resolverARPA)
}

// ddrNODATA is the local answer for a resolver.arpa query: NOERROR, no
// answer, a synthetic SOA for negative caching, and OPT echoed when the query
// had one (RFC 6891 §6.1.1; dnsproxy only adds it on its own Resolve path).
func ddrNODATA(req *dns.Msg) *dns.Msg {
	r := new(dns.Msg).SetReply(req) // mirrors ID, question, RD, CD; NOERROR
	r.RecursionAvailable = true
	r.Ns = []dns.RR{&dns.SOA{
		Hdr: dns.RR_Header{
			Name: resolverARPA, Rrtype: dns.TypeSOA,
			Class: dns.ClassINET, Ttl: ddrNegativeTTL,
		},
		Ns: "localhost.", Mbox: "nobody.invalid.",
		Serial: 1, Refresh: 3600, Retry: 600, Expire: 86400, Minttl: ddrNegativeTTL,
	}}
	if o := req.IsEdns0(); o != nil {
		r.SetEdns0(max(o.UDPSize(), dns.MinMsgSize), o.Do())
	}
	return r
}

// handleDDR is the proxy's RequestHandler. It replaces dnsproxy's default
// handling, so everything that isn't resolver.arpa goes to p.Resolve exactly
// as before. Stateless: requests are served concurrently.
func handleDDR(ctx context.Context, p *proxy.Proxy, d *proxy.DNSContext) error {
	// dnsproxy validates before calling the handler: exactly one question.
	if len(d.Req.Question) == 1 && isResolverARPA(d.Req.Question[0].Name) {
		d.Res = ddrNODATA(d.Req)
		return nil
	}
	return p.Resolve(ctx, d)
}
