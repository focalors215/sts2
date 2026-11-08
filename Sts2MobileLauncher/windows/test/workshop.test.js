'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const workshop = require('../src/main/workshop');

function tempDir() {
	return fs.mkdtempSync(path.join(os.tmpdir(), 'sts2-workshop-test-'));
}

test('parses workshop ids from numbers and links', () => {
	assert.strictEqual(workshop.parseWorkshopRef(' 3750220799 '), '3750220799');
	assert.strictEqual(workshop.parseWorkshopRef('https://steamcommunity.com/sharedfiles/filedetails/?id=3750220799&searchtext='), '3750220799');
	assert.strictEqual(workshop.parseWorkshopRef('steam://url/CommunityFilePage/x'), '');
	assert.strictEqual(workshop.parseWorkshopRef('mod name'), '');
});

test('builds the public browse URL with Android sort and time options', () => {
	const url = new URL(workshop.browseUrl({ query: ' relic ', page: 2, pageSize: 99, sort: 'lastupdated', days: 90 }));
	assert.strictEqual(url.searchParams.get('appid'), '2868840');
	assert.strictEqual(url.searchParams.get('searchtext'), 'relic');
	assert.strictEqual(url.searchParams.get('browsesort'), 'lastupdated');
	assert.strictEqual(url.searchParams.get('actualsort'), 'lastupdated');
	assert.strictEqual(url.searchParams.get('p'), '2');
	assert.strictEqual(url.searchParams.get('numperpage'), '50');
	assert.strictEqual(url.searchParams.get('days'), '90');
	assert.strictEqual(new URL(workshop.browseUrl({ sort: 'bogus', days: 3 })).searchParams.get('days'), '7');
});

test('parses legacy and SSR browse pages', () => {
	const legacy = `<div class="workshopItem"><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111&amp;searchtext=" data-appid="2868840">
		<img class="workshopItemPreviewImage aspectratio" src="https://images.steamusercontent.com/a.jpg"></a>
		<div class="workshopItemTitle ellipsis">Big &amp; Bold</div><div class="workshopItemAuthorName ellipsis">by&nbsp;<a href="x">Ann</a></div></div>
		<script>SharedFileBindMouseHover( "sharedfile_111", false, {"id":"111","description":"Hello<br>world"} );</script>
		<a class="pagebtn" href="?appid=1&p=2">></a>`;
	const page = workshop.parseBrowsePage(legacy, 1);
	assert.strictEqual(page.hasNext, true);
	assert.deepStrictEqual(page.items.map(i => [i.id, i.title, i.author, i.previewUrl, i.description]),
		[['111', 'Big & Bold', 'Ann', 'https://images.steamusercontent.com/a.jpg', 'Hello\nworld']]);
	const query = { queries: [
		{ queryKey: ['PlayerLinkDetails', '765'], state: { data: { public_data: { persona_name: 'Bob' } } } },
		{ queryKey: ['Browse'], state: { data: { current_page: 1, total_pages: 3, total_count: 61, results: [{ publishedfileid: '222', title: 'SSR mod', creator: '765', file_size: 10, time_updated: 5, preview_url: 'https://p' }] } } },
	] };
	const ssr = `<script id="valve-ssr-data" type="application/json">${JSON.stringify({ renderContext: { queryData: JSON.stringify(query) } })}</script>`;
	const parsed = workshop.parseBrowsePage(ssr, 1);
	assert.strictEqual(parsed.total, 61);
	assert.strictEqual(parsed.hasNext, true);
	assert.deepStrictEqual(parsed.items.map(i => [i.id, i.title, i.author, i.size, i.timeUpdated]), [['222', 'SSR mod', 'Bob', 10, 5]]);
	assert.deepStrictEqual(workshop.parseBrowsePage('<html></html>', 1), { items: [], hasNext: false, total: 0 });
});

test('parses details, screenshots and required items', () => {
	assert.strictEqual(workshop.parseDetail({ result: 9, publishedfileid: '1' }), null);
	const detail = workshop.parseDetail({ result: 1, publishedfileid: '333', title: 'T', file_size: '42', time_updated: 7, file_url: '', tags: [{ tag: 'QoL' }] });
	assert.deepStrictEqual([detail.id, detail.size, detail.timeUpdated, detail.tags], ['333', 42, 7, ['QoL']]);
	const html = `<div class="workshopItemDescription" id="highlightContent">Line1<br/>Line2</div>
		<script>var rgFullScreenshotURLs = [ { 'url': 'https:\\/\\/images.steamusercontent.com\\/ugc\\/1\\/', 'w': 1 }, { 'url': 'https://evil.example/x.png' } ];</script>
		<div class="requiredItemsContainer" id="RequiredItems">
			<a href="https://steamcommunity.com/workshop/filedetails/?id=444" target="_blank"><div class="requiredItem">BaseLib</div></a>
		</div></div>`;
	const community = workshop.parseCommunityDetail(html);
	assert.strictEqual(community.description, 'Line1\nLine2');
	assert.deepStrictEqual(community.screenshots, ['https://images.steamusercontent.com/ugc/1/']);
	assert.deepStrictEqual(community.required, [{ id: '444', title: 'BaseLib' }]);
});

test('loads details through GetPublishedFileDetails', async () => {
	let body;
	const fakeFetch = async (url, init) => {
		body = init.body.toString();
		return new Response(JSON.stringify({ response: { publishedfiledetails: [{ result: 1, publishedfileid: '5', title: 'Five', time_updated: 9 }] } }));
	};
	const details = await workshop.loadDetails(['5', '5'], fakeFetch);
	assert.strictEqual(body, 'itemcount=1&publishedfileids%5B0%5D=5');
	assert.strictEqual(details.get('5').title, 'Five');
});

test('finds Steam-downloaded workshop content and tracks installs and updates', () => {
	const library = tempDir();
	const content = path.join(library, 'steamapps', 'workshop', 'content', '2868840');
	fs.mkdirSync(path.join(content, '777'), { recursive: true });
	fs.mkdirSync(path.join(content, 'notanid'), { recursive: true });
	const dirs = workshop.contentDirs([library, path.join(library, 'missing')]);
	assert.deepStrictEqual([...dirs.keys()], ['777']);
	assert.strictEqual(dirs.get('777').dir, path.join(content, '777'));

	const lib = new workshop.WorkshopLibrary(path.join(tempDir(), 'workshop', 'library.json'));
	assert.deepStrictEqual(lib.list(), []);
	lib.record({ id: '777', title: 'Mod', modIds: ['ModA'], timeUpdated: 100 });
	assert.strictEqual(lib.get('777').modIds[0], 'ModA');
	assert.strictEqual(workshop.hasUpdate(lib.get('777'), { timeUpdated: 101 }), true);
	assert.strictEqual(workshop.hasUpdate(lib.get('777'), { timeUpdated: 100 }), false);
	lib.remove('777');
	assert.strictEqual(lib.get('777'), null);
});

test('downloads direct file urls with a size guard', async () => {
	const dir = tempDir();
	const file = await workshop.downloadFile('https://x.test/a.zip', path.join(dir, 'a.zip'), () => {}, async () => new Response('zipdata'));
	assert.strictEqual(fs.readFileSync(file, 'utf8'), 'zipdata');
	await assert.rejects(workshop.downloadFile('http://x.test/a.zip', path.join(dir, 'b.zip')), /workshop_bad_url/);
});
