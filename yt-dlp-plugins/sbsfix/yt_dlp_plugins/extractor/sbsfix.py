# SBS On Demand fix as a yt-dlp plugin.
#
# Official yt-dlp's SBS extractor uses the old public SMIL API, which no longer
# returns streams. This replaces it with the logged-in playback API, ported from
# the 0xvd/yt-dlp-exp fix_sbs branch (yt_dlp/extractor/sbs.py, commit 7ab76028).
# Lets the official yt-dlp.exe be updated with -U while keeping SBS working.
#
# Install: <folder with yt-dlp.exe>\yt-dlp-plugins\sbsfix\yt_dlp_plugins\extractor\sbsfix.py
# Check it loaded: yt-dlp -v ... shows "[debug] Extractor Plugins: sbsfix (SBSIE)"
# Delete this plugin once official yt-dlp ships its own SBS login fix.

import json
import time

from yt_dlp.extractor.sbs import SBSIE
from yt_dlp.networking.exceptions import HTTPError
from yt_dlp.utils import (
    ExtractorError,
    determine_ext,
    float_or_none,
    int_or_none,
    join_nonempty,
    jwt_decode_hs256,
    parse_duration,
    parse_iso8601,
    parse_qs,
    str_or_none,
    traverse_obj,
    url_or_none,
)


# Leading underscore keeps it from being registered as a second extractor;
# plugin_name makes it replace the built-in SBSIE.
class _SBSFixIE(SBSIE, plugin_name='sbsfix'):
    _NETRC_MACHINE = 'sbs'
    _ACCESS_TOKEN = None
    _REFRESH_TOKEN = None
    _LOGIN_API_BASE = 'https://auth.sbs.com.au'
    _LOGIN_API_KEY = '74165a3a-0ae7-4d27-ac1a-e71e81062a89'
    _CACHE_KEY = 'sbs_data'
    _REFRESH_COOKIE = 'auth.refresh-token'

    def _is_jwt_expired(self, token):
        return jwt_decode_hs256(token)['exp'] - time.time() < 300

    def _parse_and_cache_login_response(self, data=None):
        if not data:
            self._ACCESS_TOKEN, self._REFRESH_TOKEN = self.cache.load(
                self._NETRC_MACHINE, self._CACHE_KEY, default=[None, None])
            if self._ACCESS_TOKEN and not self._is_jwt_expired(self._ACCESS_TOKEN):
                return self._ACCESS_TOKEN
            elif self._REFRESH_TOKEN:
                return self._refresh_access_token()
            return False

        self._ACCESS_TOKEN = data.get('accessToken')
        if not self._ACCESS_TOKEN:
            raise ExtractorError('Login failed unable to get access token')
        if refresh_cookie := self._get_cookies('https://sbs.com.au').get(self._REFRESH_COOKIE):
            self._REFRESH_TOKEN = refresh_cookie.value
        self.cache.store(self._NETRC_MACHINE, self._CACHE_KEY, [self._ACCESS_TOKEN, self._REFRESH_TOKEN])
        return self._ACCESS_TOKEN, self._REFRESH_TOKEN

    def _refresh_access_token(self):
        if not self._REFRESH_TOKEN:
            self.report_warning('Unable to get refresh token')
            self._perform_login(*self._get_login_info(), force=True)
            return
        self._set_cookie('.sbs.com.au', self._REFRESH_COOKIE, self._REFRESH_TOKEN)
        try:
            data = self._download_json(
                f'{self._LOGIN_API_BASE}/refresh', None, 'Refreshing access token',
                data=json.dumps({'deviceName': 'Chrome - Linux'}).encode(),
                headers={'x-api-key': self._LOGIN_API_KEY})
        except ExtractorError as e:
            if isinstance(e.cause, HTTPError) and e.cause.status in (400, 401, 403):
                self.report_warning('Unable to get refresh token')
                self._perform_login(*self._get_login_info(), force=True)
                return
            raise
        return self._parse_and_cache_login_response(data)

    def _perform_login(self, username, password, force=False):
        if not force:
            if self._parse_and_cache_login_response():
                return
        try:
            login = self._download_json(
                f'{self._LOGIN_API_BASE}/login', None, 'Logging in',
                data=json.dumps({
                    'deviceName': 'Chrome - Linux',
                    'email': username,
                    'password': password,
                }).encode(),
                headers={'x-api-key': self._LOGIN_API_KEY})
        except ExtractorError as e:
            if isinstance(e.cause, HTTPError) and e.cause.status == 401:
                raise ExtractorError('Invalid username/password')
            raise
        return self._parse_and_cache_login_response(login)

    def _call_api(self, api, video_id, note='Downloading JSON metadata', headers=None, **kwargs):
        headers = headers or {}
        if kwargs.get('data') is not None:
            headers.setdefault('Content-Type', 'application/json')
        if access_token := self._ACCESS_TOKEN:
            headers['Authorization'] = f'Bearer {access_token}'
        return self._download_json(api, video_id, note=note, headers=headers, **kwargs)

    def _get_playback(self, video_id, note='Downloading JSON metadata'):
        # Since 2026-11-18 SBS rejects requests that don't list a DRM provider
        # ("DRM is required for this stream, but no DRM was requested"). Listing
        # one makes it also return the plain AES_HLS stream, which is the only
        # one used below; Widevine providers are skipped.
        return self._call_api(
            f'https://playback.pr.sbsod.com/stream/{video_id}', video_id, note=note,
            data=json.dumps({
                'deviceClass': 'web',
                'drm': {'level': 'L3', 'type': 'widevine'},
                'streamOptions': {'audio': 'demuxed'},
                'streamProviders': ['GoogleDAI_DRM_HLS', 'GoogleDAI_AES_HLS', 'AES_HLS'],
            }).encode())

    def _playback_error(self, e):
        # SBS explains 400/401s in a JSON "message" (expired token, DRM, geo...).
        # Error handling adapted from 0xvd's PR #16543 commit fdb2c8e1.
        if not (isinstance(e.cause, HTTPError) and e.cause.status in (401, 400)):
            return None
        return traverse_obj(
            self._parse_json(e.cause.response.read(), None, fatal=False),
            ('message', {str}), default='')

    def _raise_playback_error(self, message):
        if message:
            raise ExtractorError(f'SBS says: {message}', expected=True)
        self.raise_login_required()

    def _real_extract(self, url):
        video_id = self._match_id(url)
        try:
            media = self._get_playback(video_id)
        except ExtractorError as e:
            message = self._playback_error(e)
            if message is None:
                raise
            # Refresh and retry once, unless SBS gave a reason that isn't about
            # the token (no point retrying "DRM is required..." etc).
            token_problem = not message or any(w in message.lower() for w in ('eof', 'expire', 'token'))
            if not (self._ACCESS_TOKEN and token_problem):
                self._raise_playback_error(message)
            self._refresh_access_token()
            try:
                media = self._get_playback(video_id, 'Retrying playback after token refresh')
            except ExtractorError as e:
                message = self._playback_error(e)
                if message is None:
                    raise
                self._raise_playback_error(message)

        formats, subtitles = [], {}
        for fmt_url in traverse_obj(media, ('streamProviders', lambda _, v: not v.get('drm'), 'url')):
            ext = determine_ext(fmt_url)
            if ext == 'm3u8':
                fmts, subs = self._extract_m3u8_formats_and_subtitles(fmt_url, video_id)
            elif ext == 'mpd':
                fmts, subs = self._extract_mpd_formats_and_subtitles(fmt_url, video_id)
            else:
                continue
            formats.extend(fmts)
            self._merge_subtitles(subs, target=subtitles)

        for sub in traverse_obj(media, ('streamProviders', ..., 'textTracks', lambda _, y: y.get('url'))):
            lang = sub.get('lang', 'en')
            ext = traverse_obj(
                sub,
                ('format', {lambda x: 'vtt' if x == 'WebVTT' else None}),
                ('url', {parse_qs}, 'format', 0),
                ('url', {determine_ext(default_ext='vtt')}))
            subtitles.setdefault(lang, []).append({
                **traverse_obj(sub, {
                    'url': ('url', {url_or_none}),
                    'name': ('name', {str_or_none}),
                }),
                'ext': ext,
            })

        media.update(self._download_json(
            f'https://catalogue.pr.sbsod.com/mpx-media/{video_id}',
            video_id, fatal=not media) or {})

        # For named episodes, use the catalogue's title to set episode, rather than generic 'Episode N'.
        if traverse_obj(media, ('partOfSeries', {dict})):
            media['epName'] = traverse_obj(media, ('title', {str}))

        # Need to set different language for forced subs or else they have priority over full subs
        fixed_subtitles = {}
        for lang, subs in subtitles.items():
            for sub in subs:
                fixed_lang = lang
                if sub['url'].lower().endswith('_fe.vtt'):
                    fixed_lang += '-forced'
                fixed_subtitles.setdefault(fixed_lang, []).append(sub)

        thumbnails = []
        for thumb in traverse_obj(media, ('images', lambda _, y: y.get('id'))):
            tid = thumb.get('id')
            width, height, label = self._search_regex(
                r'\|(?P<w>\d+)\|(?P<h>\d+)\|(?P<l>[^\|]+)', thumb.get('category'),
                'thumbnail info', group=('w', 'h', 'l'), default=[None, None, None])
            thumbnails.append({
                'url': join_nonempty('https://image.pr.sbsod.com', tid, delim='/'),
                'width': int_or_none(width),
                'height': int_or_none(height),
                'id': f'{label}-{tid[:5]}',
            })

        return {
            'id': video_id,
            **traverse_obj(media, {
                'title': (('cdpTitle', 'title'), {str}),
                'description': ('description', {str}),
                'channel': ('taxonomy', 'channel', 'name', {str}),
                'series': ((('partOfSeries', 'name'), 'seriesTitle'), {str}),
                'series_id': ((('partOfSeries', 'uuid'), 'seriesID'), {str}),
                'season_number': ('seasonNumber', {int_or_none}),
                'episode': ('epName', {str}),
                'episode_number': ('episodeNumber', {int_or_none}),
                'timestamp': (('datePublished', ('publication', 'startDate')), {parse_iso8601}),
                'release_year': ('releaseYear', {int_or_none}),
                'duration': ('duration', ({float_or_none}, {parse_duration})),
                'is_live': ('liveStream', {bool}),
                'age_limit': (
                    ('classificationID', 'contentRating'), {str.upper}, {self._AUS_TV_PARENTAL_GUIDELINES.get}),
            }, get_all=False),
            **traverse_obj(media, {
                'categories': (('genres', ...), ('taxonomy', ('genre', 'subgenre'), 'name'), {str}),
                'tags': (('consumerAdviceTexts', ('sbsSubCertification', 'consumerAdvice')), ..., {str}),
            }),
            'thumbnails': thumbnails,
            'formats': formats,
            'subtitles': fixed_subtitles,
            'uploader': 'SBSC',
        }
