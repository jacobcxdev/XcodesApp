<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>{{ site.title }}</title>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        {% for release in site.data.validated_releases %}
            {% unless release.prerelease and page.release_only %}
                {% assign zip_asset = release.assets.first %}
                {% assign signature = release.body | sparkle_signature: release.tag_name %}
                {% assign description = release.body | markdownify | escape_cdata %}

                <item>
                    <title>{{ release.name | xml_escape }}</title>
                    <description><![CDATA[{{ description }}]]></description>
                    <pubDate>{{ release.published_at | date_to_rfc822 }}</pubDate>
                    {% assign build_nums = release.tag_name | replace_first:'v','' | replace_first:'b',',' | split:',' %}
                    {% assign version_number = build_nums[0] %}
                    {% assign build_number = build_nums[1] %}

                    <enclosure
                        url="{{ zip_asset.browser_download_url | xml_escape }}"
                        sparkle:version="{{ build_number | xml_escape }}"
                        sparkle:shortVersionString="{{ version_number | xml_escape }}"
                        sparkle:edSignature="{{ signature }}"
                        length="{{ zip_asset.size }}"
                        type="application/octet-stream" />
                </item>
            {% endunless %}
        {% endfor %}
    </channel>
</rss>
