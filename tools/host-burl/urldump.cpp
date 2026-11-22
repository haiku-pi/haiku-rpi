// urldump: field dump after parses, setter chains and self-aliasing calls
#include <Url.h>
#include <stdio.h>
static void dump(const char* what, const BUrl& u)
{
	printf("%-28s [%s] auth=[%s] ui=[%s] p=[%s] h=[%s] port=%d path=[%s] q=[%s] f=[%s] valid=%d\n", what,
		u.UrlString().String(), u.Authority().String(), u.UserInfo().String(), u.Protocol().String(),
		u.Host().String(), u.Port(), u.Path().String(), u.Request().String(), u.Fragment().String(), u.IsValid());
}
int main()
{
	const char* urls[] = { "http://user:pw@host:80/a/b?x=1#f", "file:///boot/home", "mailto:a@b.c", "http://h?",
		"http://[::1]:8080/p", "http://h:/p", "//h/p", "rel/path", "", "http://u@h", "data:text/plain,hi",
		"https://test-videos.co.uk/vids/x.mp4", "http://h/p#" };
	for (const char* s : urls) {
		BUrl u(s, true); dump(s, u);
		BUrl c(u); dump(" copy", c);
		BUrl a; a = u; dump(" assign", a);
		u.SetUrlString(u.UrlString(), false); dump(" self-SetUrlString", u);
		u.SetAuthority(u.Authority()); dump(" self-SetAuthority", u);
		u.SetHost(u.Host()); u.SetPath(u.Path()); dump(" self-SetHost/Path", u);
		u.SetUserName("me"); u.SetPassword("pw2"); u.SetPort(99); dump(" set user/pw/port", u);
		u.SetProtocol("ftp"); u.SetRequest("q"); u.SetFragment("z"); dump(" set proto/req/frag", u);
		BUrl r(u, BString("../x/./y?k#g")); dump(" relative", r);
		BUrl r2(u, BString("//other/z")); dump(" relative2", r2);
		printf(" equal=%d\n", (int)(c == a));
	}
	BUrl e; dump("default", e);
	return 0;
}
