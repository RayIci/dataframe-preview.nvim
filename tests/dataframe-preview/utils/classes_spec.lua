local classes = require("dataframe-preview.utils.classes")

describe("classes.not_implemented_error", function()
  it("raises an error with the function name", function()
    local ok, err = pcall(classes.not_implemented_error, "MyFunc")
    assert.is_false(ok)
    assert.truthy(err:find("MyFunc"))
  end)
end)

describe("classes.new", function()
  it("creates an instance inheriting from the class", function()
    local Base = {
      greet = function(self)
        return "hello"
      end,
    }
    local inst = classes.new(Base)
    assert.equal("hello", inst:greet())
  end)

  it("allows instance fields without affecting the class", function()
    local Base = {}
    local a = classes.new(Base)
    local b = classes.new(Base)
    a.x = 1
    assert.is_nil(b.x)
  end)
end)
