## Provider failures shared by the HTML and JSON routes.
type ApiError* = object of CatchableError
  status*: int

proc apiError*(message: string; status = 502): ref ApiError =
  result = newException(ApiError, message)
  result.status = status
