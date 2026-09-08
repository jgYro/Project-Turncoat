# Google Patents adapter API

The HappyX server exposes a JSON API and a `/patents` search page. No API key is required. These routes adapt Google Patents' **undocumented website endpoints**; they are not an official Google API and can change or become unavailable. Google's published bulk data offering is [Google Patents Public Datasets](https://github.com/google/patents-public-data), accessible through BigQuery separately.

## Search

```sh
curl --get 'http://127.0.0.1:5000/api/patents/search' \
  --data-urlencode 'q=neural network' \
  --data-urlencode 'country=US' \
  --data-urlencode 'size=10'
```

`GET /api/patents/search` accepts the following query parameters. Supply at least one query or filter. Parameters are decoded once as standard URL-encoded form values; use `%2B` for a literal plus sign. Unknown parameters are rejected.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `q` | empty | Google Patents search expression, up to 1,000 characters |
| `country` | all | Two-letter patent office code, e.g. `US`, `EP`, `WO`, `CN` |
| `assignee` | empty | Assignee name, up to 200 characters |
| `inventor` | empty | Inventor name, up to 200 characters |
| `after` | empty | Filing date after `YYYY-MM-DD` |
| `before` | empty | Filing date before `YYYY-MM-DD` |
| `sort` | `relevance` | `relevance`, `newest`, or `oldest` (filing date) |
| `page` | `1` | One-based page number |
| `size` | `10` | `10`, `25`, or `50` records per page |

The adapter forwards date filters as Google's `after=filing:YYYYMMDD` and `before=filing:YYYYMMDD`; they are **after/before boundaries**, not an inclusive date range. The after date must precede the before date. Google interprets the expression and filters; see its [search syntax documentation](https://support.google.com/faqs/answer/7049475).

The application restricts paging to the first 1,000 results. Google may expose fewer pages, so follow `has_next` and `total_pages` rather than computing page counts from `total`. The [Google results documentation](https://support.google.com/faqs/answer/7049588) describes approximate counts and grouping by simple patent family. Search requests select patent publications (`type=PATENT`).

Response shape (synthetic example):

```json
{
  "source": "Google Patents",
  "search_url": "https://patents.google.com/?q=neural+network&type=PATENT&num=10&page=0",
  "total": 23,
  "total_is_approximate": true,
  "page": 1,
  "page_size": 10,
  "total_pages": 3,
  "has_next": true,
  "results": [
    {
      "publication_number": "US1234567B1",
      "title": "Synthetic neural device …",
      "snippet": "A synthetic search excerpt.",
      "inventor": "Renée Example",
      "assignee": "Research & Development",
      "priority_date": "2019-03-01",
      "filing_date": "2020-03-01",
      "publication_date": "2021-06-10",
      "grant_date": "2021-06-10",
      "url": "https://patents.google.com/patent/US1234567B1/en",
      "pdf_url": "https://patentimages.storage.googleapis.com/aa/bb/cc/fixture/US1234567B1.pdf",
      "api_url": "/api/patents/US1234567B1"
    }
  ]
}
```

Titles and snippets come from search results and can be shortened. `inventor` and `assignee` are display strings, not complete lists. Missing optional values are empty strings. Highlight markup is removed and entities decoded; all text is plain text. Dates are supplied by the source. A missing PDF remains empty; no PDF URL is invented.

## Look up a publication

```sh
curl 'http://127.0.0.1:5000/api/patents/US9014905B1'
```

`GET /api/patents/{publication_number}` reads the publication's English document page. Lowercase identifiers are normalized to uppercase. Supply a publication number without spaces or a URL, such as `US9014905B1` or `WO2020123456A1`.

The response contains `source`, `publication_number`, `title`, `abstract`, `inventors` (array), `original_assignees` (array), `filing_date`, `publication_date`, `url`, and `pdf_url`. The title and abstract come from the document metadata rather than search snippets. Missing metadata uses empty strings or arrays. This endpoint does not extract claims, descriptions, citations, or legal status. Assignees are the original assignees in the document metadata, not a determination of current ownership.

## Errors and operational behavior

Errors use the appropriate HTTP status with this JSON shape:

```json
{"error":{"code":"invalid_request","message":"Enter a patent search term or choose a filter."}}
```

| HTTP status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | Invalid query parameters or publication identifier |
| 404 | `not_found` | The upstream publication was not found |
| 502 | `upstream_error` | Unexpected response, changed schema, redirect, or connection failure |
| 503 | `unavailable` | Local queue full or Google returned 403, 429, or 503 |
| 504 | `upstream_timeout` | The upstream request exceeded 20 seconds |

The HTML page reports the same failures and offers a link to continue searching on Google Patents. Provider redirects and access challenges are not followed or bypassed. Responses are checked for the expected schema/publication before caching; an HTML challenge cannot appear as an empty result set.

Search and lookup share a process-local queue with three seconds between completed requests and the next request. Up to eight calls can run or wait; duplicate queued calls reuse the first successful response. Successful responses are cached for 24 hours, up to 128 entries across searches and publications. Failures are not cached or retried. Responses are capped at 5 MB while reading; requests have a 20-second upstream deadline excluding queue time. Cache and pacing are shared between the JSON API and the browser page, and are separate from the arXiv queue. Run a single instance, or add shared caching and rate limiting before using replicas.

`PATENTS_ORIGIN` defaults to `https://patents.google.com`. It is a server-side override for local fixture testing; callers cannot select an upstream host. The application constructs publication links and restricts PDF links to HTTPS on `patentimages.storage.googleapis.com`.
