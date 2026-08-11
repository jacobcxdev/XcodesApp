<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>{{ site.github.project_title }}</title>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        {% for release in site.github.releases %}
            {% unless release.draft %}
                {% unless release.prerelease and page.release_only %}
                    {% assign zip_asset = nil %}
                    {% for asset in release.assets %}
                        {% if asset.name == "Xcodes.zip" %}
                            {% assign zip_asset = asset %}
                            {% break %}
                        {% endif %}
                    {% endfor %}

                    {% if zip_asset %}
                        {% assign signature = release.body | sparkle_signature: release.tag_name %}
                        {% assign description = release.body | markdownify | escape_cdata %}

                        <item>
                            <title>{{ release.name | xml_escape }}</title>
                            <description><![CDATA[{{ description }}]]></description>
                            <pubDate>{{ release.published_at | date_to_rfc822 }}</pubDate>
                            {% assign build_nums = release.tag_name | replace_first:'v','' | replace_first:'b',',' | split:',' %}
                            {% if build_nums.size == 2 %}
                                {% assign version_number = build_nums[0] %}
                                {% assign build_number = build_nums[1] %}

                                <enclosure
                                    url="{{ zip_asset.browser_download_url | xml_escape }}"
                                    sparkle:version="{{ build_number | xml_escape }}"
                                    sparkle:shortVersionString="{{ version_number | xml_escape }}"
                                    sparkle:edSignature="{{ signature }}"
                                    length="{{ zip_asset.size }}"
                                    type="application/octet-stream" />
                            {% else %}
                                {% assign version = release.tag_name | remove_first:'v' %}

                                <enclosure
                                    url="{{ zip_asset.browser_download_url | xml_escape }}"
                                    sparkle:version="{{ version | xml_escape }}"
                                    sparkle:edSignature="{{ signature }}"
                                    length="{{ zip_asset.size }}"
                                    type="application/octet-stream" />
                            {% endif %}
                        </item>
                    {% endif %}
                {% endunless %}
            {% endunless %}
        {% endfor %}
    </channel>
</rss>
