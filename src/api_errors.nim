## Provider failures shared by the HTML and JSON routes.
import std/strutils
type ApiError* = object of CatchableError
  status*: int

proc apiError*(message: string; status = 502): ref ApiError =
  result = newException(ApiError, message)
  result.status = status

proc publicMessage*(error: ref CatchableError): string =
  ## Debug-mode async exceptions append stack traces to msg; never show those in UI.
  error.msg.split("Async traceback:")[0].strip
