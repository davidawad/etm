//! `--limit` / `--offset` over a list, ntm's paging contract: the answer
//! says where the next page starts (`next_offset`, null on the last page)
//! next to a `pagination` record, so the next call is read, not computed.

use serde_json::{json, Value};

/// Keys paging adds to `data` (`--fields` never drops them).
pub const KEYS: [&str; 2] = ["pagination", "next_offset"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Page {
    pub limit: Option<usize>,
    pub offset: usize,
    /// Items in this page.
    pub count: usize,
    /// Items before paging.
    pub total: usize,
}

impl Page {
    pub fn has_more(&self) -> bool {
        self.offset + self.count < self.total
    }

    pub fn next_offset(&self) -> Option<usize> {
        self.has_more().then_some(self.offset + self.count)
    }

    pub fn to_json(&self) -> Value {
        json!({
            "limit": self.limit, "offset": self.offset, "count": self.count,
            "total": self.total, "has_more": self.has_more(),
        })
    }

    /// The command for the next page: CMD plus `--offset N [--limit L]`.
    pub fn next_command(&self, cmd: &str) -> Option<String> {
        let n = self.next_offset()?;
        Some(match self.limit {
            Some(l) => format!("{cmd} --offset {n} --limit {l}"),
            None => format!("{cmd} --offset {n}"),
        })
    }
}

/// ITEMS from OFFSET, at most LIMIT of them.
pub fn page(items: Vec<Value>, limit: Option<usize>, offset: usize) -> (Vec<Value>, Page) {
    let total = items.len();
    let kept: Vec<Value> = items
        .into_iter()
        .skip(offset)
        .take(limit.unwrap_or(usize::MAX))
        .collect();
    let p = Page {
        limit,
        offset,
        count: kept.len(),
        total,
    };
    (kept, p)
}

/// A log kept oldest first, paged from its newest end: offset 0 is the
/// newest LIMIT items (still oldest first), offset N skips the newest N.
pub fn page_newest(
    mut items: Vec<Value>,
    limit: Option<usize>,
    offset: usize,
) -> (Vec<Value>, Page) {
    items.reverse();
    let (mut kept, p) = page(items, limit, offset);
    kept.reverse();
    (kept, p)
}

/// Record P in DATA (an object): `pagination` and `next_offset`.
pub fn annotate(data: &mut Value, p: &Page) {
    if let Some(obj) = data.as_object_mut() {
        obj.insert("pagination".into(), p.to_json());
        obj.insert("next_offset".into(), json!(p.next_offset()));
    }
}

/// Page the list at DATA[KEY] in place and record it; None when DATA has
/// no such list.
pub fn paginate_key(
    data: &mut Value,
    key: &str,
    limit: Option<usize>,
    offset: usize,
) -> Option<Page> {
    let items = data.get_mut(key)?.as_array_mut().map(std::mem::take)?;
    let (kept, p) = page(items, limit, offset);
    data[key] = Value::Array(kept);
    annotate(data, &p);
    Some(p)
}

/// A list as DATA, paged: `{"items": [...], "pagination", "next_offset"}`.
pub fn paginate_list(data: Value, limit: Option<usize>, offset: usize) -> (Value, Option<Page>) {
    match data {
        Value::Array(items) => {
            let (kept, p) = page(items, limit, offset);
            let mut v = json!({"items": kept});
            annotate(&mut v, &p);
            (v, Some(p))
        }
        other => (other, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nums(n: i64) -> Vec<Value> {
        (0..n).map(|i| json!(i)).collect()
    }

    #[test]
    fn pages_walk_to_the_end() {
        let (kept, p) = page(nums(5), Some(2), 0);
        assert_eq!((kept, p.next_offset()), (vec![json!(0), json!(1)], Some(2)));
        let (kept, p) = page(nums(5), Some(2), 4);
        assert_eq!(
            (kept, p.next_offset(), p.has_more()),
            (vec![json!(4)], None, false)
        );
        let (kept, p) = page(nums(5), None, 3);
        assert_eq!((kept.len(), p.next_offset()), (2, None));
        let (kept, p) = page(nums(2), Some(2), 9);
        assert_eq!((kept.len(), p.count, p.total), (0, 0, 2));
        assert_eq!(
            page(nums(5), Some(2), 0).1.next_command("pwm ls").unwrap(),
            "pwm ls --offset 2 --limit 2"
        );
    }

    #[test]
    fn newest_pages_keep_time_order() {
        let (kept, p) = page_newest(nums(5), Some(2), 0);
        assert_eq!((kept, p.next_offset()), (vec![json!(3), json!(4)], Some(2)));
        let (kept, p) = page_newest(nums(5), Some(2), 4);
        assert_eq!((kept, p.next_offset()), (vec![json!(0)], None));
    }

    #[test]
    fn annotate_and_paginate_shapes() {
        let mut d = json!({"workspaces": nums(3), "proxies": []});
        let p = paginate_key(&mut d, "workspaces", Some(1), 1).unwrap();
        assert_eq!(d["workspaces"], json!([1]));
        assert_eq!(d["next_offset"], 2);
        assert_eq!(
            d["pagination"],
            json!({"limit": 1, "offset": 1, "count": 1, "total": 3, "has_more": true})
        );
        assert_eq!(p.count, 1);
        assert!(paginate_key(&mut d, "nope", None, 0).is_none());
        let (v, p) = paginate_list(json!(nums(2)), Some(5), 0);
        assert_eq!(
            v,
            json!({"items": [0, 1], "pagination": {"limit": 5, "offset": 0, "count": 2, "total": 2, "has_more": false}, "next_offset": null})
        );
        assert_eq!(p.unwrap().next_command("x"), None);
        assert_eq!(paginate_list(json!({"a": 1}), None, 0).1, None);
    }
}
