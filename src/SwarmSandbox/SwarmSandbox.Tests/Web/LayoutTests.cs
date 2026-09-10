using Bunit;
using SwarmSandbox.Web.Layout;
using Xunit;

namespace SwarmSandbox.Tests.Web;

public class LayoutTests : BunitContext
{
    [Fact]
    public void NavMenu_toggles_between_collapsed_and_expanded()
    {
        var cut = Render<NavMenu>();

        Assert.Contains("collapse", cut.Markup);

        cut.Find(".navbar-toggler").Click();
        Assert.DoesNotContain("collapse", cut.Markup);

        cut.Find(".navbar-toggler").Click();
        Assert.Contains("collapse", cut.Markup);
    }

    [Fact]
    public void MainLayout_renders_the_body_content_next_to_the_nav_menu()
    {
        var cut = Render<MainLayout>(ps => ps.Add(p => p.Body, "layout-body-marker"));

        Assert.Contains("layout-body-marker", cut.Markup);
        Assert.Contains("navbar-brand", cut.Markup);
        Assert.Contains("Sandboxes", cut.Markup);
    }
}
