import std/[unittest, json, os, tempfiles, asyncdispatch, unicode, strutils]
import storage/[sqlite, shares, analysis_store, driver]
import docling_extract, api_errors

suite "Investigation sharing":
  setup:
    let store=openStore(":memory:")
    store.ensureDataset("one");store.ensureDataset("two")
    store.insertNode("one",NodeRecord(oid:"one:investigation",label:"Investigation",properties: %*{"schema":"turncoat/investigation/v1","seed":"paper","publicationNumber":"Example"}))
    store.insertNode("one",NodeRecord(oid:"paper",label:"Paper",properties: %*{"title":"原始中文"}))
    store.insertNode("two",NodeRecord(oid:"unrelated",label:"Paper",properties: %*{"title":"Other dataset"}))
    store.insertEdge("one",EdgeRecord(oid:"link",source:"one:investigation",target:"paper",label:"seed",properties:newJObject()))
    store.saveReport(%*{"id":"old","dataset":"one","node":"paper","kind":"keywords","createdAt":"2026-09-09","result":{"tags":[]}})
    store.saveReport(%*{"id":"latest","dataset":"one","node":"paper","kind":"keywords","createdAt":"2026-09-09","result":{"tags":[]}})
  teardown: store.close()
  test "snapshot includes only its dataset and latest reports and stays immutable":
    let share=store.createShare("one")
    let token=share["token"].getStr
    check validShareToken(token)
    let snapshot=store.loadShare(token)
    check snapshot["nodes"].len==2 and snapshot["links"].len==1
    check snapshot["reports"].len==1
    check snapshot["reports"][0]["id"].getStr=="latest"
    store.upsertNode("one",NodeRecord(oid:"paper",label:"Paper",properties: %*{"title":"Changed"}))
    check store.loadShare(token)==snapshot
    check store.listShares("two").len==0
    check store.loadShare(store.createShare("one",false)["token"].getStr)["reports"].len==0
    expect ApiError: discard store.createShare("two")
    expect ApiError: discard store.loadShare("invalid")
  test "revocation is dataset scoped and does not delete source data":
    let token=store.createShare("one")["token"].getStr
    store.revokeShare("two",token)
    check store.loadShare(token)["nodes"].len==2
    store.revokeShare("one",token)
    expect ApiError: discard store.loadShare(token)
    check store.countNodes("one")==2
    check store.listReports("one","paper")["total"].getInt==2
  test "version-two migration and shared snapshot survive reopening":
    let directory=createTempDir("turncoat-share-","")
    var disk=openStore(directory/"test.db")
    try:
      disk.ensureDataset("saved")
      disk.insertNode("saved",NodeRecord(oid:"saved:investigation",label:"Investigation",properties: %*{"schema":"turncoat/investigation/v1"}))
      disk.db.execute("DROP TABLE analysis_jobs")
      disk.db.execute("DROP TABLE investigation_shares");disk.db.execute("PRAGMA user_version=2")
      disk.close();disk=openStore(directory/"test.db")
      check disk.db.scalarInt("PRAGMA user_version")==4
      let token=disk.createShare("saved")["token"].getStr
      disk.close();disk=openStore(directory/"test.db")
      check disk.loadShare(token)["nodes"].len==1
    finally: disk.close();removeDir(directory)

suite "Docling subprocess contract":
  test "bounded UTF-8 output, command arguments, failures and timeout":
    let binary=absolutePath("bin/docling_fixture")
    let directory=createTempDir("turncoat-ocr-fixture-","")
    try:
      let text=waitFor extractWithDocling(directory/"source.pdf",101,binary)
      check text.len<=101 and validateUtf8(text)<0
      check text.startsWith("原始中文")
      expect ApiError: discard waitFor extractWithDocling(directory/"failure.pdf",101,binary)
      try:
        discard waitFor extractWithDocling(directory/"slow.pdf",101,binary,50)
        check false
      except ApiError as error: check error.status==504
    finally: removeDir(directory)
