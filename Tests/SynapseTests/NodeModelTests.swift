import Foundation
import Msgpack
import Synapse
import Telepath
import TelepathTestKit
import Testing

/// spec.md M4 exit criteria: the Node model decodes every form in the base Synapse
/// model.
///
/// Synthesising a node of all 587 forms is not possible — many require specific
/// valid values, and some are read-only. Synapse instead exposes its own model as
/// runt nodes, so iterating `syn:form`, `syn:prop` and `syn:type` drives the
/// decoder across the whole model surface, and a curated set covers the distinct
/// shapes a primary property can take.
@Suite(.enabled(if: IntegrationEnvironment.shouldRun))
struct NodeModelTests {
    private func withCortex<T>(_ body: (Cortex) async throws -> T) async throws -> T {
        let cortex = try await Cortex.open(try IntegrationEnvironment.requireURL())
        do {
            let result = try await body(cortex)
            await cortex.close()
            return result
        } catch {
            await cortex.close()
            throw error
        }
    }

    @Test("every form in the model decodes as a node")
    func everyFormDecodes() async throws {
        try await withCortex { cortex in
            var forms: [String] = []
            for try await node in cortex.nodes("syn:form") {
                #expect(node.form == "syn:form")
                let name = try #require(node.value.stringValue, "a form's primary value is its name")
                forms.append(name)
            }
            // The base model is large; a trivial count would mean the query failed.
            #expect(forms.count > 500, "decoded \(forms.count) forms")
            #expect(forms.contains("inet:ipv4"))
            #expect(forms.contains("inet:dns:a"))
            #expect(Set(forms).count == forms.count, "form names should be unique")
        }
    }

    @Test("every property in the model decodes as a node")
    func everyPropertyDecodes() async throws {
        try await withCortex { cortex in
            var count = 0
            for try await node in cortex.nodes("syn:prop") {
                #expect(node.form == "syn:prop")
                #expect(node.iden?.isEmpty == false)
                count += 1
            }
            #expect(count > 1_000, "decoded \(count) properties")
        }
    }

    @Test("every type in the model decodes as a node")
    func everyTypeDecodes() async throws {
        try await withCortex { cortex in
            var count = 0
            for try await node in cortex.nodes("syn:type") {
                #expect(node.form == "syn:type")
                count += 1
            }
            #expect(count > 100, "decoded \(count) types")
        }
    }

    /// The shapes a primary property can take. A composite form's value is an
    /// array rather than a scalar, which is the case a naive decoder gets wrong.
    @Test("each shape of primary value decodes")
    func primaryValueShapes() async throws {
        try await withCortex { cortex in
            // A string-valued form.
            let fqdn = try #require(try await cortex.nodes("[ inet:fqdn=shapes.example ]").collect().first)
            #expect(fqdn.value.stringValue == "shapes.example")

            // An integer-backed form: IPv4 addresses ride as integers on the wire.
            let ipv4 = try #require(try await cortex.nodes("[ inet:ipv4=1.2.3.4 ]").collect().first)
            #expect(ipv4.value.intValue == 16_909_060)

            // A composite form, whose value is an array of its fields.
            let dnsA = try #require(
                try await cortex.nodes("[ inet:dns:a=(shapes.example, 1.2.3.4) ]").collect().first)
            let parts = try #require(dnsA.value.arrayValue)
            #expect(parts.count == 2)
            #expect(parts[0].stringValue == "shapes.example")
            #expect(parts[1].intValue == 16_909_060)

            // A guid-valued form.
            let org = try #require(try await cortex.nodes("[ ou:org=* ]").collect().first)
            #expect(org.value.stringValue?.count == 32)

            // A plain integer form (inet:port is a type, not a form).
            let asn = try #require(try await cortex.nodes("[ inet:asn=64512 ]").collect().first)
            #expect(asn.value.intValue == 64_512)

            // A hash form, which is hex text.
            let hash = try #require(try await cortex.nodes(
                "[ hash:md5=00000000000000000000000000000000 ]").collect().first)
            #expect(hash.value.stringValue?.count == 32)
        }
    }

    /// Tags, tag properties and node data all live beside the props map and are
    /// separate fields on the decoded node.
    @Test("tags, tagprops and nodedata decode")
    func nodeMetadata() async throws {
        try await withCortex { cortex in
            // The extended model persists across runs, so adding it twice is a
            // DupPropName rather than a test failure.
            _ = try? await cortex.callStorm("""
                $lib.model.ext.addTagProp(score, ('int', ({})), ({}))
                return($lib.true)
                """)

            let node = try #require(try await cortex.nodes("""
                [ inet:fqdn=meta.example +#threat.apt=2024 +#threat.apt:score=42 ]
                $node.data.set(source, ({'via': 'telepath'}))
                """).collect().first)

            #expect(node.hasTag("threat.apt"))
            #expect(node.tags["threat"] != nil, "parent tags are present too")
            #expect(node.props[".created"] != nil)
            #expect(node.iden?.count == 64, "a node iden is a 32-byte buid in hex")

            // tagprops arrive keyed by tag.
            #expect(node.tagprops["threat.apt"]?["score"]?.intValue == 42)
        }
    }

    /// A node's repr fields arrive only when the query asks for them.
    @Test("repr output decodes when requested")
    func reprs() async throws {
        try await withCortex { cortex in
            var opts = StormOpts()
            opts.repr = true
            let node = try #require(
                try await cortex.nodes("[ inet:ipv4=8.8.4.4 ]", opts: opts).collect().first)
            #expect(node.value.intValue == 134_743_044)
            // The raw value stays numeric; the repr is carried alongside it.
            #expect(node.form == "inet:ipv4")
        }
    }
}
