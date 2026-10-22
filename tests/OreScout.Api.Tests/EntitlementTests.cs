using OreScout.Api.Entitlements;

namespace OreScout.Api.Tests;

public class EntitlementTests
{
    [Fact]
    public void Feature_ids_are_unique()
    {
        var ids = FeatureCatalog.All.Select(f => f.Id).ToList();

        Assert.Equal(ids.Count, ids.Distinct().Count());
    }

    [Fact]
    public void Feature_ids_are_namespaced_by_kind()
    {
        // FeatureCatalog's convention: ids are namespaced layer.* / export.* / routing.*.
        string[] kinds = ["layer.", "export.", "routing."];

        Assert.All(FeatureCatalog.All, f => Assert.Contains(kinds, k => f.Id.StartsWith(k)));
    }

    [Fact]
    public void Grant_all_stub_entitles_every_catalogued_feature()
    {
        var svc = new GrantAllEntitlementService();
        var principal = EntitlementPrincipal.Anonymous;

        Assert.Equal(FeatureCatalog.All.Select(f => f.Id), svc.EntitledFeatures(principal));
        Assert.All(FeatureCatalog.All, f => Assert.True(svc.IsEntitled(principal, f.Id)));
    }
}
